import Foundation

/// One file's captured diff, for the mobile `changes.diff` RPC.
///
/// Text files carry a unified diff in ``text`` (empty when the path has no
/// changes for the requested side); binary files set ``isBinary`` and carry
/// no text. Diffs larger than ``SupermuxGitChangesService/maxFileDiffBytes``
/// are cut at the byte cap and flagged ``truncated``.
public struct SupermuxGitFileDiff: Sendable, Equatable {
    /// Whether the file is binary (no textual diff available).
    public var isBinary: Bool
    /// Unified diff text; `nil` for binary files.
    public var text: String?
    /// Whether ``text`` was cut off at the byte cap.
    public var truncated: Bool

    /// Creates a file diff.
    /// - Parameters:
    ///   - isBinary: Whether the file is binary.
    ///   - text: Unified diff text; `nil` for binary files.
    ///   - truncated: Whether the text was byte-capped.
    public init(isBinary: Bool, text: String?, truncated: Bool) {
        self.isBinary = isBinary
        self.text = text
        self.truncated = truncated
    }
}

/// The per-file diff capture behind the mobile `changes.diff` RPC.
///
/// Split out of `SupermuxGitChangesService.swift` to keep the service file
/// inside the fork's Swift file-length budget.
extension SupermuxGitChangesService {
    /// Byte cap for one file's diff text on the wire. Large enough for any
    /// reviewable diff, small enough that a lockfile-churn rewrite cannot
    /// balloon one RPC response into hundreds of megabytes.
    public static let maxFileDiffBytes = 262_144

    /// Captures the unified diff for one repo-relative path.
    ///
    /// `staged` selects the index-vs-HEAD diff (`git diff --cached`);
    /// otherwise the worktree-vs-index diff (`git diff`). An untracked path
    /// (not in the index) is previewed as a full addition via
    /// `git diff --no-index /dev/null <path>`, matching what staging it would
    /// introduce. Binary files are detected with `--numstat` (binary entries
    /// print `-` counters) and return ``SupermuxGitFileDiff/isBinary`` with no
    /// text. Text is captured through a base64-armored shell pipeline so
    /// non-UTF-8 content cannot nil the runner's strict stdout decode, and is
    /// byte-capped at ``maxFileDiffBytes`` (`head -c` stops the pipe early, so
    /// a huge diff returns fast instead of being captured whole).
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - path: Repo-relative path to diff.
    ///   - staged: Whether to diff the index (`--cached`) instead of the
    ///     working tree.
    /// - Returns: The captured diff; never throws — a failing git invocation
    ///   degrades to an empty text diff (callers treat the path as unchanged).
    public func fileDiff(repoPath: String, path: String, staged: Bool) async -> SupermuxGitFileDiff {
        // The untracked preview shells out to `git diff --no-index`, which reads
        // exactly the operand path git is handed — and unlike a real pathspec
        // diff, git does NOT confine `--no-index` operands to the repository. So
        // for that branch we hand git the RESOLVED, repo-confined absolute path
        // (not the caller's string). Reading the same object that passed
        // confinement removes the interior-symlink-rebind race: a concurrent
        // `files.rename` that re-points a directory in the caller's path can no
        // longer make git open a file outside the repo, because git never
        // re-walks the caller-controlled components.
        var noIndexResolvedPath: String?
        if !staged {
            noIndexResolvedPath = await untrackedResolvedPath(repoPath: repoPath, path: path)
        }
        if await isBinaryDiff(
            repoPath: repoPath, path: path, staged: staged, noIndexResolvedPath: noIndexResolvedPath
        ) {
            return SupermuxGitFileDiff(isBinary: true, text: nil, truncated: false)
        }
        let (text, truncated) = await diffText(
            repoPath: repoPath, path: path, staged: staged, noIndexResolvedPath: noIndexResolvedPath
        )
        return SupermuxGitFileDiff(isBinary: false, text: text, truncated: truncated)
    }

    // MARK: - Internals

    /// The resolved, repo-confined absolute path when `path` names an untracked
    /// file that is a genuine working-tree change — else nil. Returns the
    /// RESOLVED path (the object that passed confinement) so the caller hands
    /// git a concrete path rather than re-walking caller-controlled symlink
    /// components at read time. An absolute, `..`, or symlink-escaping path
    /// resolves to nil and is never previewed via `--no-index`.
    ///
    /// "Not in the index" alone is NOT enough to preview: a `.gitignored` file
    /// (an `.env` secret) or a `.git/` internal is also absent from the index,
    /// but it is not a change the Changes screen shows, so dumping its bytes
    /// would leak a file the user never staged. So an ignored path
    /// (`git check-ignore`) and any `.git/` path are excluded first; only then
    /// does an untracked (`ls-files --error-unmatch` miss) file qualify — which
    /// still covers untracked files reached through an interior symlink that
    /// resolves inside the repo (git may not list those under `ls-files
    /// --others`, but they are legitimate previews).
    private func untrackedResolvedPath(repoPath: String, path: String) async -> String? {
        guard let resolved = Self.repoConfinedExistingPath(repoPath: repoPath, path: path) else {
            return nil
        }
        // Evaluate the ignore/`.git` rules against the RESOLVED target, not the
        // caller's alias: an untracked symlink `leak -> .env` (or `-> .git/…`)
        // is itself neither ignored nor a `.git` path, so a check on the
        // textual request path would slip the ignored secret / git internal
        // through `--no-index`. `repoConfinedExistingPath` already proved the
        // target stays inside the repo, so its repo-relative form is safe here.
        let canonicalRoot = URL(fileURLWithPath: repoPath).resolvingSymlinksInPath().path
        let target = Self.repoRelativePath(resolved, canonicalRoot: canonicalRoot) ?? path
        // Case-insensitive: on the default case-insensitive macOS volume `.GIT`
        // resolves to `.git`, and git treats them as the same directory.
        if (target as NSString).pathComponents
            .contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) {
            return nil
        }
        // Never preview an ignored file (check-ignore exits 0 when ignored).
        let ignored = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "check-ignore", "-q", "--", target],
            timeout: Self.gitTimeout
        )
        if ignored.exitStatus == 0 { return nil }
        // Otherwise preview only a genuinely untracked file (not in the index).
        let tracked = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "ls-files", "--error-unmatch", "--", target],
            timeout: Self.gitTimeout
        )
        return tracked.exitStatus != 0 ? resolved : nil
    }

    /// The repo-relative form of an absolute path already known to be inside
    /// `canonicalRoot` (`""` for the root itself), or nil when it is not.
    private static func repoRelativePath(_ absolutePath: String, canonicalRoot: String) -> String? {
        if absolutePath == canonicalRoot { return "" }
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        return String(absolutePath.dropFirst(prefix.count))
    }

    /// Resolves `path` against the repository root and returns the absolute
    /// path only when it names an existing file that stays inside the
    /// repository: relative, no `..` components, and — after resolving
    /// symlinks on both sides — still prefixed by the canonical repo root.
    /// `nil` for anything else (absolute paths, traversal, symlink escapes,
    /// or a missing file).
    static func repoConfinedExistingPath(repoPath: String, path: String) -> String? {
        guard !path.hasPrefix("/") else { return nil }
        let components = (path as NSString).pathComponents
        guard !components.contains("..") else { return nil }
        let canonicalRoot = URL(fileURLWithPath: repoPath).resolvingSymlinksInPath().path
        let fullPath = (canonicalRoot as NSString).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fullPath) else { return nil }
        let resolved = URL(fileURLWithPath: fullPath).resolvingSymlinksInPath().path
        guard resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/") else {
            return nil
        }
        return resolved
    }

    /// Whether git reports the path's diff as binary: a `--numstat` record for
    /// a binary file prints `-` for both line counters. Captured through the
    /// base64-armored pipeline so a non-UTF-8 filename cannot nil the capture
    /// into a false negative.
    private func isBinaryDiff(
        repoPath: String, path: String, staged: Bool, noIndexResolvedPath: String?
    ) async -> Bool {
        let script = "git \(Self.noOptionalLocks) "
            + diffArguments(staged: staged, noIndex: noIndexResolvedPath != nil, extra: "--numstat -z")
            + " \(pathspec(path: path, noIndexResolvedPath: noIndexResolvedPath)) | /usr/bin/base64"
        let result = await runShellPipeline(script, in: repoPath, shell: "/bin/bash")
        guard let armored = result.stdout,
              let data = Data(base64Encoded: armored, options: .ignoreUnknownCharacters)
        else { return false }
        return String(decoding: data, as: UTF8.self).hasPrefix("-\t-\t")
    }

    /// Captures the byte-capped unified diff text. `head -c` reads one byte
    /// past the cap so truncation is detected exactly; the exit status is
    /// deliberately ignored (git exits via SIGPIPE when `head` stops early,
    /// and `--no-index` exits 1 whenever the files differ).
    private func diffText(
        repoPath: String, path: String, staged: Bool, noIndexResolvedPath: String?
    ) async -> (text: String, truncated: Bool) {
        let script = "git \(Self.noOptionalLocks) "
            + diffArguments(staged: staged, noIndex: noIndexResolvedPath != nil, extra: nil)
            + " \(pathspec(path: path, noIndexResolvedPath: noIndexResolvedPath))"
            + " | /usr/bin/head -c \(Self.maxFileDiffBytes + 1) | /usr/bin/base64"
        let result = await runShellPipeline(script, in: repoPath, shell: "/bin/bash")
        guard let armored = result.stdout,
              let data = Data(base64Encoded: armored, options: .ignoreUnknownCharacters)
        else { return ("", false) }
        let truncated = data.count > Self.maxFileDiffBytes
        let bounded = truncated ? data.prefix(Self.maxFileDiffBytes) : data
        return (String(decoding: bounded, as: UTF8.self), truncated)
    }

    /// The `diff` invocation for the requested side: `--cached` for the
    /// index, `--no-index` for untracked previews, plain otherwise.
    private func diffArguments(staged: Bool, noIndex: Bool, extra: String?) -> String {
        var parts = ["diff"]
        if staged { parts.append("--cached") }
        if noIndex { parts.append("--no-index") }
        if let extra { parts.append(extra) }
        return parts.joined(separator: " ")
    }

    /// The quoted pathspec. For a `--no-index` untracked preview the operand is
    /// the RESOLVED absolute path (`-- /dev/null <resolved>`), so git opens the
    /// exact object that passed confinement; otherwise the repo-relative path
    /// (`-- <path>`), which git itself confines to the repository.
    private func pathspec(path: String, noIndexResolvedPath: String?) -> String {
        if let resolved = noIndexResolvedPath {
            return "-- /dev/null \(Self.shellQuoted(resolved))"
        }
        return "-- \(Self.shellQuoted(path))"
    }

    /// Single-quotes `value` for safe interpolation into a shell script.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

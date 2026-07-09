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
        var noIndex = false
        if !staged {
            noIndex = await isUntrackedPath(repoPath: repoPath, path: path)
        }
        if await isBinaryDiff(repoPath: repoPath, path: path, staged: staged, noIndex: noIndex) {
            return SupermuxGitFileDiff(isBinary: true, text: nil, truncated: false)
        }
        let (text, truncated) = await diffText(
            repoPath: repoPath, path: path, staged: staged, noIndex: noIndex
        )
        return SupermuxGitFileDiff(isBinary: false, text: text, truncated: truncated)
    }

    // MARK: - Internals

    /// Whether `path` is untracked: not in the index (`ls-files
    /// --error-unmatch` fails) while present on disk.
    private func isUntrackedPath(repoPath: String, path: String) async -> Bool {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "ls-files", "--error-unmatch", "--", path],
            timeout: Self.gitTimeout
        )
        guard result.exitStatus != 0 else { return false }
        let fullPath = (repoPath as NSString).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: fullPath)
    }

    /// Whether git reports the path's diff as binary: a `--numstat` record for
    /// a binary file prints `-` for both line counters. Captured through the
    /// base64-armored pipeline so a non-UTF-8 filename cannot nil the capture
    /// into a false negative.
    private func isBinaryDiff(
        repoPath: String, path: String, staged: Bool, noIndex: Bool
    ) async -> Bool {
        let script = "git \(Self.noOptionalLocks) "
            + diffArguments(staged: staged, noIndex: noIndex, extra: "--numstat -z")
            + " \(pathspec(path: path, noIndex: noIndex)) | /usr/bin/base64"
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
        repoPath: String, path: String, staged: Bool, noIndex: Bool
    ) async -> (text: String, truncated: Bool) {
        let script = "git \(Self.noOptionalLocks) "
            + diffArguments(staged: staged, noIndex: noIndex, extra: nil)
            + " \(pathspec(path: path, noIndex: noIndex))"
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

    /// The quoted pathspec: `-- <path>`, prefixed with `/dev/null` for
    /// `--no-index` untracked previews (full-addition diff).
    private func pathspec(path: String, noIndex: Bool) -> String {
        let quoted = Self.shellQuoted(path)
        return noIndex ? "-- /dev/null \(quoted)" : "-- \(quoted)"
    }

    /// Single-quotes `value` for safe interpolation into a shell script.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

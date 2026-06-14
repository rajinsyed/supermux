public import CmuxProcess
import Foundation

/// Reads and mutates git working-tree state for the supermux changes panel.
///
/// Provides the status snapshot behind ``SupermuxChangesModel`` plus the
/// stage/unstage/discard/commit/push/pull mutations the panel exposes. All
/// git invocations go through an injected ``CommandRunning`` so tests can run
/// against fixture repositories (or fake runners) without touching the
/// user's machine. Local commands use a 30 second timeout; network commands
/// (`push`/`pull`) get 120 seconds.
public actor SupermuxGitChangesService {
    private let runner: any CommandRunning
    private let parser = SupermuxGitStatusParser()
    private static let gitTimeout: TimeInterval = 30
    private static let networkTimeout: TimeInterval = 120

    /// Creates a service.
    /// - Parameter runner: Executes git; defaults to a production ``CommandRunner``.
    public init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// Reads the repository status at `repoPath`.
    ///
    /// Runs `git status --porcelain=v2 --branch` and parses the output with
    /// ``SupermuxGitStatusParser``.
    /// - Parameter repoPath: Directory to inspect.
    /// - Returns: The parsed snapshot, or
    ///   ``SupermuxGitStatusSnapshot/notARepository`` when git fails or the
    ///   path is not inside a repository.
    public func status(repoPath: String) async -> SupermuxGitStatusSnapshot {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: ["status", "--porcelain=v2", "--branch"],
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0, let stdout = result.stdout else {
            return .notARepository
        }
        return parser.parse(stdout)
    }

    /// Stages the given repo-relative paths (`git add -- <paths>`).
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - paths: Repo-relative paths to stage; no-op when empty.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func stage(repoPath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await runGit(in: repoPath, ["add", "--"] + paths, commandLabel: "add")
    }

    /// Stages everything, including untracked files (`git add -A`).
    /// - Parameter repoPath: Repository directory.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func stageAll(repoPath: String) async throws {
        try await runGit(in: repoPath, ["add", "-A"], commandLabel: "add -A")
    }

    /// Unstages the given repo-relative paths (`git reset -q HEAD -- <paths>`).
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - paths: Repo-relative paths to unstage; no-op when empty.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func unstage(repoPath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await runGit(in: repoPath, ["reset", "-q", "HEAD", "--"] + paths, commandLabel: "reset")
    }

    /// Unstages everything (`git reset -q HEAD`).
    /// - Parameter repoPath: Repository directory.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func unstageAll(repoPath: String) async throws {
        try await runGit(in: repoPath, ["reset", "-q", "HEAD"], commandLabel: "reset")
    }

    /// Discards the working-tree change for a single file.
    ///
    /// Untracked files are deleted from disk. Renamed files restore the
    /// original path from `HEAD` and remove the renamed-to file when it is not
    /// itself tracked in `HEAD` — otherwise the rename would be only half
    /// undone, leaving the moved file behind as untracked. All other kinds run
    /// `git checkout -- <path>`.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - change: The change to discard.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git
    ///   errors, or the underlying `FileManager` error when deleting a file fails.
    public func discard(repoPath: String, change: SupermuxGitFileChange) async throws {
        switch change.kind {
        case .untracked:
            let fullPath = (repoPath as NSString).appendingPathComponent(change.path)
            try FileManager.default.removeItem(atPath: fullPath)
        case .renamed:
            var restorePaths: [String] = []
            if let oldPath = change.oldPath, await existsInHEAD(repoPath: repoPath, path: oldPath) {
                restorePaths.append(oldPath)
            }
            let newPathInHEAD = await existsInHEAD(repoPath: repoPath, path: change.path)
            if newPathInHEAD {
                restorePaths.append(change.path)
            }
            if restorePaths.isEmpty { restorePaths = [change.path] }
            try await runGit(in: repoPath, ["checkout", "--"] + restorePaths, commandLabel: "checkout")
            // The renamed-to file is the moved copy; when it is not a tracked
            // HEAD path, restoring the original leaves it on disk. Remove it so
            // the rename is fully discarded.
            if !newPathInHEAD {
                let movedPath = (repoPath as NSString).appendingPathComponent(change.path)
                if FileManager.default.fileExists(atPath: movedPath) {
                    try? FileManager.default.removeItem(atPath: movedPath)
                }
            }
        default:
            try await runGit(in: repoPath, ["checkout", "--", change.path], commandLabel: "checkout")
        }
    }

    /// Discards every working-tree change, restoring the tree to `HEAD`.
    ///
    /// Runs `git reset --hard HEAD` to throw away all staged and unstaged
    /// modifications to tracked files, then `git clean -fd` to delete untracked
    /// files and directories. Ignored files are left untouched (no `-x`).
    /// - Parameter repoPath: Repository directory.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func discardAll(repoPath: String) async throws {
        try await runGit(in: repoPath, ["reset", "--hard", "HEAD"], commandLabel: "reset --hard")
        try await runGit(in: repoPath, ["clean", "-fd"], commandLabel: "clean")
    }

    /// Reads up to `limit` unpushed local commits (newest first): commits in
    /// `HEAD` that are not yet on the remote.
    ///
    /// With an upstream configured, the range is `@{upstream}..HEAD` (exactly
    /// the commits the branch is "ahead" by). Without one — a never-pushed or
    /// detached branch — it falls back to `HEAD --not --remotes`, i.e. commits
    /// reachable from `HEAD` that are not on any remote-tracking branch (in a
    /// repository with no remotes at all, that is the whole local history,
    /// which is correct: nothing has been pushed).
    ///
    /// Runs `git log -z --no-color --no-show-signature` with
    /// ``SupermuxGitCommit/logFormat``; `--no-show-signature` keeps GPG
    /// verification lines out of the stream for users with
    /// `log.showSignature=true`. Returns an empty array when git fails —
    /// including an empty repository / unborn branch or a missing upstream
    /// ref — so a missing list degrades quietly rather than as an error.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - hasUpstream: Whether the current branch has an upstream configured.
    ///   - limit: Maximum number of commits to return.
    /// - Returns: The parsed unpushed commits, newest first, or `[]` on failure.
    public func unpushedCommits(
        repoPath: String, hasUpstream: Bool, limit: Int
    ) async -> [SupermuxGitCommit] {
        guard limit > 0 else { return [] }
        let revision = hasUpstream ? ["@{upstream}..HEAD"] : ["HEAD", "--not", "--remotes"]
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [
                "log", "-z", "--no-color", "--no-show-signature",
                "--max-count=\(limit)", "--format=\(SupermuxGitCommit.logFormat)",
            ] + revision,
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0, let stdout = result.stdout else { return [] }
        return SupermuxGitCommit.parse(log: stdout)
    }

    /// Commits staged changes (`git commit -m <message>`).
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - message: Commit message.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` carrying
    ///   stderr/stdout detail (for example "nothing to commit") on failure.
    public func commit(repoPath: String, message: String) async throws {
        try await runGit(in: repoPath, ["commit", "-m", message], commandLabel: "commit")
    }

    /// A non-mutating diff of everything a "stage all + commit" would capture,
    /// for AI commit-message generation.
    ///
    /// Combines `git diff HEAD --stat` + `git diff HEAD` (all tracked changes vs
    /// the last commit, staged or not) with a list of untracked files. It does
    /// **not** touch the index, so the caller can generate a message first and
    /// only stage when a message is in hand (keeping the operation atomic).
    /// Returns an empty string when there is nothing to commit or the path is
    /// not a repository. On an unborn branch `git diff HEAD` fails and only the
    /// untracked listing is returned.
    /// - Parameter repoPath: Repository directory.
    public func uncommittedDiff(repoPath: String) async -> String {
        let stat = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: ["diff", "HEAD", "--stat"],
            timeout: Self.gitTimeout
        )
        let patch = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: ["diff", "HEAD"],
            timeout: Self.gitTimeout
        )
        let untracked = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: ["ls-files", "--others", "--exclude-standard"],
            timeout: Self.gitTimeout
        )
        var parts: [String] = []
        if let summary = stat.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append(summary)
        }
        if let body = patch.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            parts.append(body)
        }
        if let files = untracked.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !files.isEmpty {
            parts.append("New untracked files:\n" + files)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Pushes the current branch.
    ///
    /// Runs `git push` when an upstream is configured, otherwise
    /// `git push -u origin HEAD` to create and track `origin/<branch>`.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - hasUpstream: Whether the current branch already has an upstream.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func push(repoPath: String, hasUpstream: Bool) async throws {
        let arguments = hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"]
        try await runGit(in: repoPath, arguments, commandLabel: "push", timeout: Self.networkTimeout)
    }

    /// Pulls from the configured upstream (`git pull`).
    /// - Parameter repoPath: Repository directory.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func pull(repoPath: String) async throws {
        try await runGit(in: repoPath, ["pull"], commandLabel: "pull", timeout: Self.networkTimeout)
    }

    // MARK: - Internals

    /// Whether `path` exists as a blob/tree in `HEAD`.
    private func existsInHEAD(repoPath: String, path: String) async -> Bool {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: ["cat-file", "-e", "HEAD:\(path)"],
            timeout: Self.gitTimeout
        )
        return result.exitStatus == 0
    }

    @discardableResult
    private func runGit(
        in directory: String,
        _ arguments: [String],
        commandLabel: String,
        timeout: TimeInterval = SupermuxGitChangesService.gitTimeout
    ) async throws -> CommandResult {
        let result = await runner.run(
            directory: directory,
            executable: "git",
            arguments: arguments,
            timeout: timeout
        )
        guard result.exitStatus == 0 else {
            throw SupermuxGitError.gitFailed(command: commandLabel, message: Self.failureMessage(result))
        }
        return result
    }

    private static func failureMessage(_ result: CommandResult) -> String {
        if let error = result.executionError { return error }
        if result.timedOut {
            return String(localized: "supermux.changes.gitTimedOut", defaultValue: "timed out")
        }
        let stderr = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stdout.isEmpty { return stdout }
        let status = result.exitStatus.map(String.init) ?? "unknown"
        return String(localized: "supermux.changes.gitExitStatus", defaultValue: "exit status \(status)")
    }
}

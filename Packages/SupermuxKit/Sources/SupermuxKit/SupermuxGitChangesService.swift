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
    /// Shorter deadline for the best-effort background fetch: it runs on a timer
    /// and must give up quickly (and retry next cycle) rather than linger on a
    /// stalled network or auth like the user-initiated push/pull paths.
    private static let fetchTimeout: TimeInterval = 30

    /// Creates a service.
    /// - Parameter runner: Executes git; defaults to a production ``CommandRunner``.
    public init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// Reads the repository status at `repoPath`.
    ///
    /// Runs `git status --porcelain=v2 --branch --show-stash` and parses the
    /// output with ``SupermuxGitStatusParser``. `--show-stash` folds the stash
    /// depth (`# stash <n>`) into the same invocation that drives every refresh,
    /// so the panel can gate Pop Stash without spawning a second git process.
    /// - Parameter repoPath: Directory to inspect.
    /// - Returns: The parsed snapshot, or
    ///   ``SupermuxGitStatusSnapshot/notARepository`` when git fails or the
    ///   path is not inside a repository.
    public func status(repoPath: String) async -> SupermuxGitStatusSnapshot {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: ["status", "--porcelain=v2", "--branch", "--show-stash"],
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
        if hasUpstream,
           let upstreamCommits = await commitLog(
               repoPath: repoPath, revision: ["@{upstream}..HEAD"], limit: limit
           ) {
            return upstreamCommits
        }
        // No upstream, or the `@{upstream}` range failed (e.g. the
        // remote-tracking ref is missing locally): fall back to "not on any
        // remote" rather than misleadingly claiming nothing is unpushed.
        return await commitLog(
            repoPath: repoPath, revision: ["HEAD", "--not", "--remotes"], limit: limit
        ) ?? []
    }

    /// Counts unpushed commits for a branch with no upstream:
    /// `git rev-list --count HEAD --not --remotes` — commits reachable from
    /// `HEAD` but not on any remote-tracking branch (the same set
    /// ``unpushedCommits(repoPath:hasUpstream:limit:)`` falls back to).
    ///
    /// Used only when `git status` reports no `ahead` count to drive the panel's
    /// "hide the Unpushed section when empty" decision without loading the whole
    /// list. Returns `0` on failure (e.g. an unborn branch) or an empty range.
    /// - Parameter repoPath: Repository directory.
    public func unpushedCountWithoutUpstream(repoPath: String) async -> Int {
        let stdout = await runner.runStandardOutput(
            directory: repoPath,
            executable: "git",
            arguments: ["rev-list", "--count", "HEAD", "--not", "--remotes"],
            timeout: Self.gitTimeout
        )
        return stdout.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    /// Reads up to `limit` incoming commits (newest first): commits on the
    /// upstream that are not yet in `HEAD` — exactly what `git pull` would bring.
    ///
    /// The range is `HEAD..@{upstream}`. The remote-tracking ref is only as
    /// fresh as the last `git fetch`, so callers run ``fetch(repoPath:)`` first
    /// to surface commits pushed elsewhere (e.g. a merged worktree). Unlike
    /// ``unpushedCommits(repoPath:hasUpstream:limit:)`` there is no
    /// remotes-based fallback: with no upstream there is nothing to pull, so an
    /// empty array is returned. Also `[]` when the range is empty or git fails
    /// (for example a detached HEAD without `@{upstream}`).
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - limit: Maximum number of commits to return.
    /// - Returns: The parsed incoming commits, newest first, or `[]`.
    public func incomingCommits(repoPath: String, limit: Int) async -> [SupermuxGitCommit] {
        guard limit > 0 else { return [] }
        return await commitLog(
            repoPath: repoPath, revision: ["HEAD..@{upstream}"], limit: limit
        ) ?? []
    }

    /// Runs `git log` over `revision` and parses the result; `nil` on git
    /// failure (so callers can fall back) versus `[]` for a successful empty
    /// range.
    private func commitLog(
        repoPath: String, revision: [String], limit: Int
    ) async -> [SupermuxGitCommit]? {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [
                "log", "-z", "--no-color", "--no-show-signature",
                "--max-count=\(limit)", "--format=\(SupermuxGitCommit.logFormat)",
            ] + revision,
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0, let stdout = result.stdout else { return nil }
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

    /// Best-effort `git fetch` that refreshes the remote-tracking refs without
    /// merging, so the ahead/behind counts and the incoming/outgoing commit
    /// lists reflect what is on the remote (e.g. a worktree merged elsewhere).
    ///
    /// Runs `git fetch --no-tags --quiet` with no remote argument: the default
    /// refspec is what updates `refs/remotes/<remote>/*` — and therefore
    /// `@{upstream}` and `behind` — whereas an explicit `git fetch <remote>
    /// <branch>` would only move `FETCH_HEAD`.
    ///
    /// The background fetch must be fully non-interactive: a credential or SSH
    /// prompt would otherwise pop a GUI or stall until the timeout. Because the
    /// shared ``CommandRunner`` cannot set a per-command environment, git is run
    /// via `/usr/bin/env` with the prompt/askpass knobs cleared
    /// (`GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`/`SSH_ASKPASS=/usr/bin/false`,
    /// `GCM_INTERACTIVE=never`), so a missing credential fails fast; stored
    /// credentials (e.g. the keychain helper) are still consulted first and keep
    /// working. A short ``fetchTimeout`` bounds the network call, and the result
    /// is a flag rather than a throw — an auto-fetch that fails (offline, no
    /// remote, auth) must degrade quietly and never surface as a user error.
    ///
    /// Running through `/usr/bin/env` bypasses ``CommandRunner``'s own
    /// PATH/bundled-bin/fallback resolution (every other call passes
    /// `executable: "git"`), so `env` would otherwise resolve `git` against only
    /// the GUI process's minimal inherited `PATH` (`/usr/bin:/bin:…`) and miss a
    /// Homebrew/MacPorts git. We therefore set `PATH` explicitly to the inherited
    /// value plus the same fallback directories the runner searches, so the
    /// background fetch finds git wherever the foreground git calls do.
    /// - Parameter repoPath: Repository directory.
    /// - Returns: `true` when git exited cleanly, otherwise `false`.
    @discardableResult
    public func fetch(repoPath: String) async -> Bool {
        let result = await runner.run(
            directory: repoPath,
            executable: "/usr/bin/env",
            arguments: [
                "PATH=\(Self.gitSearchPath)",
                "GIT_TERMINAL_PROMPT=0",
                "GIT_ASKPASS=/usr/bin/false",
                "SSH_ASKPASS=/usr/bin/false",
                "GCM_INTERACTIVE=never",
                "git", "fetch", "--no-tags", "--quiet",
            ],
            timeout: Self.fetchTimeout
        )
        return result.exitStatus == 0
    }

    /// `PATH` for the `env`-launched background fetch: the inherited `PATH` first
    /// (so a user's custom git wins, matching ``CommandRunner``'s search order),
    /// then the runner's fallback directories and the standard system bins.
    private static let gitSearchPath: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"]
        let fallbacks = CommandRunner.defaultFallbackSearchDirectories
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let parts = ([inherited].compactMap { $0 } + fallbacks).filter { !$0.isEmpty }
        return parts.joined(separator: ":")
    }()

    // MARK: - Stash

    /// Stashes working-tree changes (`git stash push`).
    ///
    /// By default only tracked-file changes (staged or unstaged) are stashed;
    /// pass `includeUntracked` to add `--include-untracked` so untracked files
    /// are stashed too. `git stash push` exits `0` with "No local changes to
    /// save" when there is nothing to stash, so this never throws on a clean
    /// tree — callers gate the action on having changes.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - includeUntracked: Whether to also stash untracked files.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func stash(repoPath: String, includeUntracked: Bool) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        try await runGit(
            in: repoPath, arguments,
            commandLabel: includeUntracked ? "stash push --include-untracked" : "stash push"
        )
    }

    /// Restores the most recent stash and drops it (`git stash pop`).
    ///
    /// A `pop` that produces merge conflicts exits non-zero and leaves the
    /// stash in place with conflict markers in the working tree; that surfaces
    /// as a ``SupermuxGitError/gitFailed(command:message:)`` for the caller to
    /// show, while the conflicted files appear on the next status refresh.
    /// - Parameter repoPath: Repository directory.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func popStash(repoPath: String) async throws {
        try await runGit(in: repoPath, ["stash", "pop"], commandLabel: "stash pop")
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

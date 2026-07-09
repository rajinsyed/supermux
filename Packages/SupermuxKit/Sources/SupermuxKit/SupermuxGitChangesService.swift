public import CmuxFoundation
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
    // `runner`, `gitTimeout`, and `noOptionalLocks` are internal (not
    // private): also used by the AI-capture extension in
    // `SupermuxGitChangesService+AICapture.swift`.
    let runner: any CommandRunning
    private let parser = SupermuxGitStatusParser()
    static let gitTimeout: TimeInterval = 30
    private static let networkTimeout: TimeInterval = 120
    /// Shorter deadline for the best-effort background fetch: it runs on a timer
    /// and must give up quickly (and retry next cycle) rather than linger on a
    /// stalled network or auth like the user-initiated push/pull paths.
    private static let fetchTimeout: TimeInterval = 30
    /// Global git flag prepended to every read-only invocation so a refresh
    /// never takes the optional `.git/index` lock (or rewrites the index),
    /// which would re-trigger the FSEvents watcher that requested the refresh.
    static let noOptionalLocks = "--no-optional-locks"

    /// Creates a service.
    /// - Parameter runner: Executes git; defaults to a production ``CommandRunner``.
    public init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// Reads the repository status at `repoPath`.
    ///
    /// Runs `git status --porcelain=v2 -z --branch --show-stash` and parses the
    /// output with ``SupermuxGitStatusParser``. `-z` makes git print paths
    /// verbatim (no C-quoting of non-ASCII/special filenames) with
    /// NUL-terminated records. `--show-stash` folds the stash depth
    /// (`# stash <n>`) into the same invocation that drives every refresh,
    /// so the panel can gate Pop Stash without spawning a second git process.
    /// - Parameter repoPath: Directory to inspect.
    /// - Returns: The parsed snapshot, or
    ///   ``SupermuxGitStatusSnapshot/notARepository`` when git fails or the
    ///   path is not inside a repository.
    public func status(repoPath: String) async -> SupermuxGitStatusSnapshot {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [
                Self.noOptionalLocks, "status", "--porcelain=v2", "-z", "--branch", "--show-stash",
            ],
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0 else {
            return .notARepository
        }
        guard let stdout = result.stdout, !stdout.isEmpty else {
            // git succeeded but the capture is unusable. nil: the output
            // failed CommandRunner's strict UTF-8 decode — with `-z` git
            // prints path bytes verbatim, so a single non-UTF-8 filename
            // anywhere in the repo (e.g. a latin-1 name committed on Linux)
            // nils the ENTIRE stdout. Empty: impossible from a successful
            // `--branch` status (the branch headers always print), i.e. a
            // transient pipe-read artifact under subprocess load. Recapture
            // (lossily) so the panel degrades to one mangled filename — or
            // just re-reads the real output — instead of falsely reporting
            // "not a repository" with every action disabled.
            return await statusViaLossyCapture(repoPath: repoPath)
        }
        return parser.parse(stdout)
    }

    /// Fallback status capture for repositories whose `-z` output is not valid
    /// UTF-8. Base64-armors the bytes through the shell (pure ASCII, so the
    /// runner's strict decode always succeeds), then decodes them lossily:
    /// the offending filename renders with U+FFFD replacement characters (its
    /// per-file mutations fail cleanly against the mangled path) while every
    /// other file and panel action stays fully operable. `pipefail` keeps
    /// git's own failure (repo deleted between the two captures) detectable.
    ///
    /// The recapture also absorbs ``CommandRunner``'s partial/empty-read
    /// artifact (a transient of the concurrent pipe reads, shared by every
    /// runner call site) — it is not purely an encoding fallback.
    private func statusViaLossyCapture(repoPath: String) async -> SupermuxGitStatusSnapshot {
        let script = "set -o pipefail; git \(Self.noOptionalLocks) status"
            + " --porcelain=v2 -z --branch --show-stash | /usr/bin/base64"
        let result = await runShellPipeline(script, in: repoPath, shell: "/bin/bash")
        guard result.exitStatus == 0,
              let armored = result.stdout,
              let data = Data(base64Encoded: armored, options: .ignoreUnknownCharacters),
              !data.isEmpty
        else { return .notARepository }
        return parser.parse(String(decoding: data, as: UTF8.self))
    }

    /// Byte budget for one `git add` invocation's joined pathspec arguments:
    /// well under the kernel's ARG_MAX so a huge multi-select can never fail
    /// exec, with a path-count cap as a second bound.
    private static let maxStageChunkBytes = 100_000
    private static let maxStageChunkPaths = 500

    /// Stages the given repo-relative paths (`git add -- <paths>`), chunked so
    /// each argv stays under ``maxStageChunkBytes`` / ``maxStageChunkPaths``.
    ///
    /// `git add` is all-or-nothing per invocation: one bad pathspec (a file
    /// vanished between status and stage) fails the whole call with nothing
    /// staged. A failed chunk therefore falls back to per-path adds so the
    /// survivors still stage, and the per-path failures are aggregated into a
    /// single thrown error. Deleted *tracked* paths stay in the batches
    /// unconditionally — their pathspecs match the index, so staging the
    /// deletion succeeds.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - paths: Repo-relative paths to stage; no-op when empty.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` aggregating
    ///   every path that could not be staged.
    public func stage(repoPath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        var failures: [String] = []
        for chunk in Self.stageChunks(paths) {
            do {
                try await runGit(in: repoPath, ["add", "--"] + chunk, commandLabel: "add")
            } catch {
                for path in chunk {
                    do {
                        try await runGit(in: repoPath, ["add", "--", path], commandLabel: "add")
                    } catch SupermuxGitError.gitFailed(_, let message) {
                        failures.append("\(path): \(message)")
                    }
                }
            }
        }
        guard failures.isEmpty else {
            throw SupermuxGitError.gitFailed(command: "add", message: failures.joined(separator: "\n"))
        }
    }

    /// Splits `paths` into `git add` argv chunks bounded by
    /// ``maxStageChunkBytes`` joined path bytes and ``maxStageChunkPaths``
    /// entries; a single oversized path still gets its own chunk.
    private static func stageChunks(_ paths: [String]) -> [[String]] {
        var chunks: [[String]] = []
        var chunk: [String] = []
        var chunkBytes = 0
        for path in paths {
            let bytes = path.utf8.count + 1
            if !chunk.isEmpty,
               chunkBytes + bytes > maxStageChunkBytes || chunk.count >= maxStageChunkPaths {
                chunks.append(chunk)
                chunk = []
                chunkBytes = 0
            }
            chunk.append(path)
            chunkBytes += bytes
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
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

    /// Unstages everything (`git reset -q`).
    ///
    /// No explicit `HEAD`: on a born branch `git reset -q` behaves identically,
    /// while on an unborn branch (fresh `git init`, nothing committed) `HEAD`
    /// does not resolve and the explicit form fails with "ambiguous argument".
    /// - Parameter repoPath: Repository directory.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func unstageAll(repoPath: String) async throws {
        try await runGit(in: repoPath, ["reset", "-q"], commandLabel: "reset")
    }

    /// Discards the working-tree change for a single file.
    ///
    /// Untracked files are deleted from disk. Renamed files restore the
    /// original path from `HEAD` and remove the renamed-to file when it is not
    /// itself tracked in `HEAD` — otherwise the rename would be only half
    /// undone, leaving the moved file behind as untracked. Conflicted files
    /// present in `HEAD` restore its content (`git checkout HEAD -- <path>`),
    /// which also clears the unmerged index entry — the plain
    /// `git checkout -- <path>` form refuses unmerged paths outright.
    /// Conflicted paths absent from `HEAD` (deleted-by-us, added-by-them,
    /// both-deleted) are discarded via `git rm -f -- <path>` instead: it
    /// clears all unmerged stages and removes the working file when present,
    /// succeeding even when the file is already gone — the checkout form has
    /// no `HEAD` content to restore and `git restore --source=HEAD` errors
    /// with "path is unmerged". All other kinds run `git checkout -- <path>`.
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
        case .conflicted:
            if await existsInHEAD(repoPath: repoPath, path: change.path) {
                try await runGit(
                    in: repoPath, ["checkout", "HEAD", "--", change.path], commandLabel: "checkout HEAD"
                )
            } else {
                try await runGit(in: repoPath, ["rm", "-f", "--", change.path], commandLabel: "rm -f")
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
    /// On an unborn branch (no commits yet) `HEAD` does not resolve, so the
    /// reset falls back to `git reset -q` — there is no commit to restore
    /// tracked content from; unstaging plus the clean is the whole discard.
    /// - Parameter repoPath: Repository directory.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func discardAll(repoPath: String) async throws {
        if await headExists(repoPath: repoPath) {
            try await runGit(in: repoPath, ["reset", "--hard", "HEAD"], commandLabel: "reset --hard")
        } else {
            try await runGit(in: repoPath, ["reset", "-q"], commandLabel: "reset")
        }
        try await runGit(in: repoPath, ["clean", "-fd"], commandLabel: "clean")
    }

    /// Whether `HEAD` resolves to a commit (`false` on an unborn branch).
    private func headExists(repoPath: String) async -> Bool {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "rev-parse", "--verify", "--quiet", "HEAD"],
            timeout: Self.gitTimeout
        )
        return result.exitStatus == 0
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

    // The AI-flow change captures (`uncommittedDiff`, its bounded patch, and
    // the untracked-content identity) live in
    // `SupermuxGitChangesService+AICapture.swift` (Swift file-length budget).

    /// Pushes the current branch.
    ///
    /// Runs `git push` when an upstream is configured, otherwise
    /// `git push -u origin HEAD` to create and track `origin/<branch>`.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - hasUpstream: Whether the current branch already has an upstream.
    /// - Returns: git's captured output (stdout/stderr), for callers that
    ///   surface a transfer log (the mobile `changes.push` `log_lines`).
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    @discardableResult
    public func push(repoPath: String, hasUpstream: Bool) async throws -> CommandResult {
        let arguments = hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"]
        return try await runGit(
            in: repoPath, arguments, commandLabel: "push", timeout: Self.networkTimeout
        )
    }

    /// Pulls from the configured upstream (`git pull`).
    /// - Parameter repoPath: Repository directory.
    /// - Returns: git's captured output (stdout/stderr), for callers that
    ///   surface a transfer log (the mobile `changes.pull` `log_lines`).
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    @discardableResult
    public func pull(repoPath: String) async throws -> CommandResult {
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

    /// `PATH` for every `env`-launched git call (the `runGit` mutations, the
    /// background fetch, the AI-capture shell pipelines): the inherited `PATH`
    /// first (so a user's custom git wins, matching ``CommandRunner``'s search
    /// order), then the runner's fallback directories and the standard system
    /// bins. Mutations need it too, not just resolution: repo hooks inherit
    /// this `PATH` (see `runGit`). Internal (not private): also used by
    /// `SupermuxGitChangesService+AICapture.swift`.
    static let gitSearchPath: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"]
        let fallbacks = CommandRunner.defaultFallbackSearchDirectories
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let parts = ([inherited].compactMap { $0 } + fallbacks).filter { !$0.isEmpty }
        return parts.joined(separator: ":")
    }()

    /// Runs a shell pipeline with ``gitSearchPath`` as its `PATH` — the shared
    /// shape for every `env`-launched capture (`statusViaLossyCapture` plus the
    /// AI captures in `SupermuxGitChangesService+AICapture.swift`). The
    /// background ``fetch(repoPath:)`` deliberately does not route through
    /// here: it runs git directly (no shell) with askpass env and its own
    /// shorter timeout.
    func runShellPipeline(
        _ script: String, in directory: String, shell: String = "/bin/sh"
    ) async -> CommandResult {
        await runner.run(
            directory: directory,
            executable: "/usr/bin/env",
            arguments: ["PATH=\(Self.gitSearchPath)", shell, "-c", script],
            timeout: Self.gitTimeout
        )
    }

    // MARK: - Internals
    //
    // The stash operations live in `SupermuxGitChangesService+Stash.swift`
    // (Swift file-length budget).

    /// Whether `path` exists as a blob/tree in `HEAD`.
    private func existsInHEAD(repoPath: String, path: String) async -> Bool {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "cat-file", "-e", "HEAD:\(path)"],
            timeout: Self.gitTimeout
        )
        return result.exitStatus == 0
    }

    // Internal (not private): also used by the stash extension in
    // `SupermuxGitChangesService+Stash.swift`.
    //
    // Launched via `/usr/bin/env PATH=…` rather than `executable: "git"`:
    // ``CommandRunner`` resolves the git binary itself against its fallback
    // directories, but it does not amend the child's environment, so a GUI app
    // launched from the Dock hands git the minimal launchd `PATH`
    // (`/usr/bin:/bin:…`). Repo hooks then inherit that `PATH` and anything
    // they invoke from Homebrew//usr/local — e.g. a husky pre-commit running
    // `bunx` — fails with "command not found" (127). Setting `PATH` to
    // ``gitSearchPath`` gives the hooks the same search path the runner uses.
    @discardableResult
    func runGit(
        in directory: String,
        _ arguments: [String],
        commandLabel: String,
        timeout: TimeInterval = SupermuxGitChangesService.gitTimeout
    ) async throws -> CommandResult {
        let result = await runner.run(
            directory: directory,
            executable: "/usr/bin/env",
            arguments: ["PATH=\(Self.gitSearchPath)", "git"] + arguments,
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

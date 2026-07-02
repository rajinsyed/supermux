public import CmuxFoundation
import Foundation
import os

/// Creates, lists, and removes git worktrees for supermux projects.
///
/// Follows the piggycode conventions: worktrees live under
/// `<root>/<worktreesDirName>/<branch>`, new branches are created with
/// `--no-track` from a chosen base, `push.autoSetupRemote` is enabled in the
/// new checkout, and the base branch is recorded in
/// `branch.<name>.base` for later comparison UIs.
///
/// All git invocations go through an injected ``CommandRunning`` so tests can
/// run against fixture repositories (or fake runners) without touching the
/// user's machine.
public actor SupermuxGitWorktreeService {
    private let runner: any CommandRunning
    private let naming: SupermuxBranchName
    private static let gitTimeout: TimeInterval = 30
    /// Deadline for checkout-weight commands (`worktree add`/`worktree remove`):
    /// they populate or delete a full working tree — LFS smudge filters included —
    /// so the blanket 30s would kill them mid-flight on large repositories.
    private static let checkoutTimeout: TimeInterval = 600
    /// Upper bound for a worktree teardown script; cleanup that runs longer is
    /// terminated so a hung script can never wedge worktree deletion.
    private static let teardownTimeout: TimeInterval = 120
    /// `PATH` for the one `env`-launched git call (the `worktree add`):
    /// `/usr/bin/env` bypasses ``CommandRunner``'s own executable resolution,
    /// so `git` is re-resolved against the inherited `PATH` plus the runner's
    /// fallback dirs (mirrors `SupermuxGitChangesService.gitSearchPath`).
    private static let gitSearchPath: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"]
        let fallbacks = CommandRunner.defaultFallbackSearchDirectories
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return ([inherited].compactMap { $0 } + fallbacks).filter { !$0.isEmpty }.joined(separator: ":")
    }()
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "supermux.worktree")

    /// Creates a service.
    /// - Parameters:
    ///   - runner: Executes git; defaults to a production ``CommandRunner``.
    ///   - naming: Branch naming policy; defaults to the standard one.
    public init(runner: any CommandRunning = CommandRunner(), naming: SupermuxBranchName = SupermuxBranchName()) {
        self.runner = runner
        self.naming = naming
    }

    /// Whether `path` is inside a git work tree.
    /// - Parameter path: Directory to probe.
    public func isGitRepository(at path: String) async -> Bool {
        let result = await runner.run(
            directory: path,
            executable: "git",
            arguments: ["rev-parse", "--is-inside-work-tree"],
            timeout: Self.gitTimeout
        )
        return result.exitStatus == 0 && result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The repository's current short branch name, or `nil` when detached or
    /// not a repository.
    /// - Parameter repoRoot: Repository root path.
    public func currentBranch(repoRoot: String) async -> String? {
        let result = await runner.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["symbolic-ref", "--short", "HEAD"],
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0 else { return nil }
        let name = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// All local branch names, most recently committed first.
    /// - Parameter repoRoot: Repository root path.
    public func localBranches(repoRoot: String) async -> [String] {
        let result = await runner.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"],
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0, let stdout = result.stdout else { return [] }
        return stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Lists the project's linked worktrees (the primary checkout is omitted).
    /// - Parameter project: The project whose repository is inspected.
    /// - Returns: Worktrees in `git worktree list` order.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    public func listWorktrees(for project: SupermuxProject) async throws -> [SupermuxProjectWorktree] {
        let result = await runner.run(
            directory: project.rootPath,
            executable: "git",
            arguments: ["worktree", "list", "--porcelain"],
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0, let stdout = result.stdout else {
            throw SupermuxGitError.gitFailed(
                command: "worktree list",
                message: Self.failureMessage(result)
            )
        }
        let rootPath = SupermuxWorktreePath.canonical(project.rootPath)
        let worktreesDir = SupermuxWorktreePath.worktreesDir(canonicalRoot: rootPath, project: project)
        // Only treat worktrees under a worktrees dir whose configured name is
        // genuinely inside the project as "managed" (the escape test is lexical;
        // see `SupermuxWorktreePath.lexicalWorktreesDir`). If a corrupt config
        // (e.g. "..") escaped the root, fall back to a sentinel that matches
        // nothing so no sibling worktree is ever reported deletable.
        let lexicalWorktreesDir = SupermuxWorktreePath.lexicalWorktreesDir(canonicalRoot: rootPath, project: project)
        let managedPrefix = lexicalWorktreesDir.hasPrefix(rootPath + "/") ? worktreesDir + "/" : "\u{0}"
        var worktrees: [SupermuxProjectWorktree] = []
        var path: String?
        var branch: String?
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.isEmpty, let entryPath = path {
                let normalized = SupermuxWorktreePath.canonical(entryPath)
                if normalized != rootPath {
                    worktrees.append(SupermuxProjectWorktree(
                        path: normalized,
                        branch: branch,
                        isSupermuxManaged: normalized.hasPrefix(managedPrefix)
                    ))
                }
                path = nil
                branch = nil
            }
        }
        if let entryPath = path {
            let normalized = SupermuxWorktreePath.canonical(entryPath)
            if normalized != rootPath {
                worktrees.append(SupermuxProjectWorktree(
                    path: normalized,
                    branch: branch,
                    isSupermuxManaged: normalized.hasPrefix(managedPrefix)
                ))
            }
        }
        return worktrees
    }

    /// Creates a new worktree with a fresh branch.
    ///
    /// The branch name is sanitized and deduplicated; the worktree is created
    /// at `<root>/<worktreesDir>/<branch>` from `baseBranch` (local first,
    /// then `origin/<baseBranch>`, defaulting to `HEAD`).
    /// - Parameters:
    ///   - project: Target project; must be a git repository.
    ///   - requestedBranch: Raw branch name input from the user.
    ///   - baseBranch: Base branch override; `nil` uses the project default or `HEAD`.
    /// - Returns: The created worktree.
    /// - Throws: ``SupermuxGitError`` describing the failure.
    public func createWorktree(
        project: SupermuxProject,
        requestedBranch: String,
        baseBranch: String? = nil
    ) async throws -> SupermuxProjectWorktree {
        guard await isGitRepository(at: project.rootPath) else {
            throw SupermuxGitError.notAGitRepository(path: project.rootPath)
        }
        // A blank (or all-invalid) branch field generates a friendly random
        // name instead of erroring, so worktree creation is never blocked on
        // naming — matching piggycode's "leave it empty" affordance.
        let sanitized = naming.sanitize(requestedBranch) ?? naming.randomName()

        let rootPath = SupermuxWorktreePath.canonical(project.rootPath)
        // The worktrees container must stay strictly inside the project root:
        // an escaping config is a hard error here (the guard is lexical; see
        // `SupermuxWorktreePath.lexicalWorktreesDir`).
        let lexicalWorktreesDir = SupermuxWorktreePath.lexicalWorktreesDir(canonicalRoot: rootPath, project: project)
        guard lexicalWorktreesDir.hasPrefix(rootPath + "/") else {
            throw SupermuxGitError.unsafeWorktreePath(path: lexicalWorktreesDir)
        }
        // Canonical (symlink-resolved) container for everything compared
        // against `git worktree list` realpath output.
        let worktreesDir = SupermuxWorktreePath.worktreesDir(canonicalRoot: rootPath, project: project)

        let base = try await resolveBase(
            repoRoot: rootPath,
            requested: baseBranch ?? project.defaultBranch
        )

        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        await ensureWorktreesDirIgnored(project: project)

        // Two attempts: the actor is reentrant, so a concurrent creation can
        // claim the deduplicated name between our branch snapshot and the add;
        // a fresh dedup on the retry resolves that race. The retry fires ONLY
        // on git's name/path/ref-claim rejection: an add can create the
        // branch AND register the worktree yet still exit non-zero (a failing
        // post-checkout hook), and a bare ref-exists check would then retry
        // `<name>-2` next to the half-created worktree. Other failures surface.
        var attemptsRemaining = 2
        while true {
            attemptsRemaining -= 1
            let branch = await deduplicatedBranch(for: sanitized, project: project, rootPath: rootPath, worktreesDir: worktreesDir)
            let directoryName = naming.directoryComponent(for: branch)
            let worktreePath = SupermuxWorktreePath.normalized((worktreesDir as NSString).appendingPathComponent(directoryName))
            guard worktreePath.hasPrefix(worktreesDir + "/") else {
                throw SupermuxGitError.unsafeWorktreePath(path: worktreePath)
            }

            // The retry gate string-matches the add's stderr, so `LC_ALL=C`
            // keeps it locale-stable (gettext git localizes it); `env`
            // re-resolves `git` itself, so `PATH` must be passed too.
            let add = await runner.run(
                directory: rootPath,
                executable: "/usr/bin/env",
                arguments: [
                    "PATH=\(Self.gitSearchPath)", "LC_ALL=C",
                    "git", "worktree", "add", "--no-track", "-b", branch, worktreePath, base.startPoint,
                ],
                timeout: Self.checkoutTimeout
            )
            if add.exitStatus == 0 {
                // Make the first `git push` in the worktree create origin/<branch>.
                _ = try? await runGit(
                    in: worktreePath,
                    ["config", "--local", "push.autoSetupRemote", "true"],
                    commandLabel: "config push.autoSetupRemote"
                )
                if let baseName = base.recordedName {
                    _ = try? await runGit(
                        in: rootPath,
                        ["config", "branch.\(branch).base", baseName],
                        commandLabel: "config branch base"
                    )
                }
                return SupermuxProjectWorktree(path: worktreePath, branch: branch, isSupermuxManaged: true)
            }
            if add.timedOut {
                await cleanUpTimedOutAdd(branch: branch, worktreePath: worktreePath, rootPath: rootPath)
            } else if attemptsRemaining > 0,
                      Self.isNameClaimRejection(add.stderr, branch: branch, worktreePath: worktreePath),
                      await refExists(repoRoot: rootPath, ref: "refs/heads/\(branch)") {
                continue
            }
            throw SupermuxGitError.gitFailed(command: "worktree add", message: Self.failureMessage(add))
        }
    }

    /// Whether a failed `worktree add`'s stderr is git rejecting the specific
    /// branch or checkout path we tried to claim ("fatal: a branch named
    /// '<branch>' already exists" / "fatal: '<path>' already exists"), or the
    /// ref-lock collision the same race produces when two adds hit the ref
    /// near-simultaneously ("cannot lock ref 'refs/heads/<branch>'") — the
    /// failure shapes the reentrancy race produces. The interpolated
    /// branch/path keeps unrelated hook output that happens to say "already
    /// exists" from triggering a retry; git wording drift degrades to not
    /// retrying rather than to retrying after a partial add. The caller
    /// conjoins this with a ref-exists check (two factors: the message shape
    /// AND the branch genuinely taken).
    private static func isNameClaimRejection(
        _ stderr: String?, branch: String, worktreePath: String
    ) -> Bool {
        guard let stderr = stderr?.lowercased() else { return false }
        return stderr.contains("branch named '\(branch.lowercased())' already exists")
            || stderr.contains("'\(worktreePath.lowercased())' already exists")
            || stderr.contains("cannot lock ref 'refs/heads/\(branch.lowercased())'")
    }

    /// Deduplicates `sanitized` against local branches *and* the worktree
    /// directory names already claimed — on disk or still registered with git
    /// (a manually deleted checkout keeps its registration and would make
    /// `git worktree add` fail at the same path).
    private func deduplicatedBranch(
        for sanitized: String,
        project: SupermuxProject,
        rootPath: String,
        worktreesDir: String
    ) async -> String {
        let branches = await localBranches(repoRoot: rootPath)
        var takenDirectories = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: worktreesDir)) ?? []
        )
        if let registered = try? await listWorktrees(for: project) {
            for worktree in registered
            where (worktree.path as NSString).deletingLastPathComponent == worktreesDir {
                takenDirectories.insert((worktree.path as NSString).lastPathComponent)
            }
        }
        return naming.deduplicate(sanitized, existing: branches, takenDirectories: takenDirectories)
    }

    /// Best-effort teardown after a timed-out `worktree add`. The SIGKILL that
    /// follows the deadline can interrupt git's own junk cleanup, and the
    /// freshly created branch always survives it — left in place it would make
    /// a same-name retry silently become `<name>-2`. Deleting the branch is
    /// safe: had it pre-existed, the add would have failed up-front instead of
    /// timing out mid-checkout.
    private func cleanUpTimedOutAdd(branch: String, worktreePath: String, rootPath: String) async {
        _ = try? await runGit(
            in: rootPath,
            ["worktree", "remove", "--force", worktreePath],
            commandLabel: "worktree remove",
            timeout: Self.checkoutTimeout
        )
        if FileManager.default.fileExists(atPath: worktreePath) {
            try? FileManager.default.removeItem(atPath: worktreePath)
        }
        _ = try? await runGit(in: rootPath, ["worktree", "prune"], commandLabel: "worktree prune")
        _ = try? await runGit(in: rootPath, ["branch", "-D", branch], commandLabel: "branch -D")
    }

    /// Removes a supermux-managed worktree.
    /// - Parameters:
    ///   - worktree: Worktree to remove; must be ``SupermuxProjectWorktree/isSupermuxManaged``.
    ///   - project: Owning project.
    ///   - force: Removes even with uncommitted changes.
    ///   - deleteBranch: Also deletes the worktree's local branch (`git branch -D`).
    /// - Throws: ``SupermuxGitError`` describing the failure.
    public func removeWorktree(
        _ worktree: SupermuxProjectWorktree,
        project: SupermuxProject,
        force: Bool = false,
        deleteBranch: Bool = false
    ) async throws {
        guard worktree.isSupermuxManaged else {
            throw SupermuxGitError.unmanagedWorktree(path: worktree.path)
        }
        // A checkout whose directory is already gone (deleted in Finder or a
        // terminal) has no uncommitted work to lose, and the status probe
        // cannot even launch there — skip straight to git-native removal,
        // which handles the stale registration. Otherwise a status failure
        // stays fail-closed as dirty: the guard protects real work.
        if !force, FileManager.default.fileExists(atPath: worktree.path) {
            let status = await runner.run(
                directory: worktree.path,
                executable: "git",
                // --ignore-submodules=none: once removal passes --force (below) it
                // bypasses git's own dirty check, so this guard is the only thing
                // protecting uncommitted work — make it see submodule changes too,
                // regardless of the user's diff.ignoreSubmodules config.
                arguments: ["status", "--porcelain", "--ignore-submodules=none"],
                timeout: Self.gitTimeout
            )
            let dirty = !(status.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if status.exitStatus != 0 || dirty {
                throw SupermuxGitError.dirtyWorktree(path: worktree.path)
            }
        }
        // Run the project's teardown script while the checkout still exists, but
        // only now that removal is actually going ahead (past the dirty guard).
        await runTeardownIfNeeded(worktree: worktree, project: project)
        // Removal always passes --force. The dirty guard above is the sole
        // safeguard for the user's uncommitted work, so by this point deletion is
        // already authorized and the only things git would still refuse are ones
        // we want to override: a checkout teardown just dirtied, and — since git
        // 2.17 — a worktree containing initialized submodules (which cmux/supermux
        // repos ship, and which otherwise fails with "working trees containing
        // submodules cannot be moved or removed"). --force waives both in one
        // git-native removal that also cleans up the worktree's admin entry.
        try await runGit(
            in: project.rootPath,
            ["worktree", "remove", "--force", worktree.path],
            commandLabel: "worktree remove",
            timeout: Self.checkoutTimeout
        )
        if deleteBranch, let branch = worktree.branch {
            _ = try? await runGit(in: project.rootPath, ["branch", "-D", branch], commandLabel: "branch -D")
        }
    }

    // MARK: - Internals

    /// Runs the project's teardown commands in `worktree` if any are configured.
    ///
    /// Executed headless as `env KEY=VALUE … <login-shell> -lc <script>`: the
    /// variables go through `/usr/bin/env` (no shell quoting needed), and `-l`
    /// makes the shell source the user's profile so `PATH`/tooling resolve — a
    /// GUI app otherwise inherits a minimal environment. The script is
    /// non-interactive, so interactive-only `.zshrc` aliases will not exist;
    /// teardown is expected to call binaries/scripts, not shell aliases.
    ///
    /// Best-effort: a missing checkout, a non-zero exit, or a timeout is logged
    /// and never blocks removal. The script may dirty the checkout, but that is
    /// fine because ``removeWorktree`` always force-removes afterwards.
    private func runTeardownIfNeeded(worktree: SupermuxProjectWorktree, project: SupermuxProject) async {
        guard let body = SupermuxWorktreeScript.joined(project.teardownCommands) else { return }
        guard FileManager.default.fileExists(atPath: worktree.path) else { return }
        let environment = SupermuxWorktreeEnvironment.variables(
            projectRoot: project.rootPath,
            worktreePath: worktree.path
        )
        let shellEnv = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let shell = shellEnv.isEmpty ? "/bin/zsh" : shellEnv
        let arguments = SupermuxWorktreeScript.envAssignments(environment) + [shell, "-lc", body]
        let result = await runner.run(
            directory: worktree.path,
            executable: "/usr/bin/env",
            arguments: arguments,
            timeout: Self.teardownTimeout
        )
        if result.timedOut || result.executionError != nil || result.exitStatus != 0 {
            Self.logger.warning(
                "teardown failed for \(worktree.path, privacy: .public): \(Self.failureMessage(result), privacy: .public)"
            )
        }
    }

    private struct ResolvedBase {
        /// What `git worktree add` checks out from (e.g. `main`, `origin/main`, `HEAD`).
        var startPoint: String
        /// The plain branch name recorded in `branch.<new>.base`, or `nil` for `HEAD`.
        var recordedName: String?
    }

    private func resolveBase(repoRoot: String, requested: String?) async throws -> ResolvedBase {
        guard let requested, !requested.isEmpty, requested != "HEAD" else {
            return ResolvedBase(startPoint: "HEAD", recordedName: nil)
        }
        if await refExists(repoRoot: repoRoot, ref: "refs/heads/\(requested)") {
            return ResolvedBase(startPoint: requested, recordedName: requested)
        }
        if await refExists(repoRoot: repoRoot, ref: "refs/remotes/origin/\(requested)") {
            return ResolvedBase(startPoint: "origin/\(requested)", recordedName: requested)
        }
        throw SupermuxGitError.unknownBaseBranch(name: requested)
    }

    private func refExists(repoRoot: String, ref: String) async -> Bool {
        let result = await runner.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["show-ref", "--verify", "--quiet", ref],
            timeout: Self.gitTimeout
        )
        return result.exitStatus == 0
    }

    /// Appends the worktrees directory to `.git/info/exclude` so the
    /// container never shows up as untracked (mirrors the piggycode setup).
    private func ensureWorktreesDirIgnored(project: SupermuxProject) async {
        let result = await runner.run(
            directory: project.rootPath,
            executable: "git",
            arguments: ["rev-parse", "--git-common-dir"],
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0, var gitDir = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !gitDir.isEmpty else { return }
        if !(gitDir as NSString).isAbsolutePath {
            gitDir = (project.rootPath as NSString).appendingPathComponent(gitDir)
        }
        let infoDir = (gitDir as NSString).appendingPathComponent("info")
        let excludePath = (infoDir as NSString).appendingPathComponent("exclude")
        let pattern = "/\(project.worktreesDirName)/"
        let existing: String
        if FileManager.default.fileExists(atPath: excludePath) {
            // git imposes no encoding on exclude files. Never rewrite one we
            // cannot decode losslessly — the exclusion is best-effort, the
            // user's existing patterns are not.
            guard let decoded = try? String(contentsOfFile: excludePath, encoding: .utf8) else { return }
            existing = decoded
        } else {
            existing = ""
        }
        guard !existing.components(separatedBy: .newlines).contains(pattern) else { return }
        try? FileManager.default.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
        let updated = existing.isEmpty ? pattern + "\n" : existing.trimmingCharacters(in: .newlines) + "\n" + pattern + "\n"
        try? updated.write(toFile: excludePath, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func runGit(
        in directory: String,
        _ arguments: [String],
        commandLabel: String,
        timeout: TimeInterval = SupermuxGitWorktreeService.gitTimeout
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
        if result.timedOut { return "timed out" }
        let stderr = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderr.isEmpty { return stderr }
        return "exit status \(result.exitStatus.map(String.init) ?? "unknown")"
    }

}

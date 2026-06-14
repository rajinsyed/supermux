public import CmuxProcess
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
    /// Upper bound for a worktree teardown script; cleanup that runs longer is
    /// terminated so a hung script can never wedge worktree deletion.
    private static let teardownTimeout: TimeInterval = 120
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
        let rootPath = Self.normalizedPath(project.rootPath)
        let worktreesDir = Self.normalizedPath(project.worktreesDirPath)
        // Only treat worktrees under a worktrees dir that is genuinely inside
        // the project as "managed". If a corrupt config escaped the root, fall
        // back to a sentinel that matches nothing so no sibling worktree is
        // ever reported deletable.
        let managedPrefix = worktreesDir.hasPrefix(rootPath + "/") ? worktreesDir + "/" : "\u{0}"
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
                let normalized = Self.normalizedPath(entryPath)
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
            let normalized = Self.normalizedPath(entryPath)
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
        let branch = naming.deduplicate(sanitized, existing: await localBranches(repoRoot: project.rootPath))

        let rootPath = Self.normalizedPath(project.rootPath)
        let worktreesDir = Self.normalizedPath(project.worktreesDirPath)
        // The worktrees container must stay strictly inside the project root —
        // a corrupt/hand-edited `worktreesDirName` like ".." would otherwise
        // resolve to the parent directory and let worktrees (and deletions)
        // escape into sibling repositories.
        guard worktreesDir.hasPrefix(rootPath + "/") else {
            throw SupermuxGitError.unsafeWorktreePath(path: worktreesDir)
        }
        let directoryName = naming.directoryComponent(for: branch)
        let worktreePath = Self.normalizedPath((worktreesDir as NSString).appendingPathComponent(directoryName))
        guard worktreePath.hasPrefix(worktreesDir + "/") else {
            throw SupermuxGitError.unsafeWorktreePath(path: worktreePath)
        }

        let base = try await resolveBase(
            repoRoot: project.rootPath,
            requested: baseBranch ?? project.defaultBranch
        )

        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        await ensureWorktreesDirIgnored(project: project)

        try await runGit(
            in: project.rootPath,
            ["worktree", "add", "--no-track", "-b", branch, worktreePath, base.startPoint],
            commandLabel: "worktree add"
        )
        // Make the first `git push` in the worktree create origin/<branch>.
        _ = try? await runGit(
            in: worktreePath,
            ["config", "--local", "push.autoSetupRemote", "true"],
            commandLabel: "config push.autoSetupRemote"
        )
        if let baseName = base.recordedName {
            _ = try? await runGit(
                in: project.rootPath,
                ["config", "branch.\(branch).base", baseName],
                commandLabel: "config branch base"
            )
        }
        return SupermuxProjectWorktree(path: worktreePath, branch: branch, isSupermuxManaged: true)
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
        if !force {
            let status = await runner.run(
                directory: worktree.path,
                executable: "git",
                arguments: ["status", "--porcelain"],
                timeout: Self.gitTimeout
            )
            let dirty = !(status.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if status.exitStatus != 0 || dirty {
                throw SupermuxGitError.dirtyWorktree(path: worktree.path)
            }
        }
        // Run the project's teardown script while the checkout still exists, but
        // only now that removal is actually going ahead (past the dirty guard).
        let ranTeardown = await runTeardownIfNeeded(worktree: worktree, project: project)
        var arguments = ["worktree", "remove"]
        // Force the removal when the user asked, or when teardown ran: a teardown
        // script may have written/removed files in a worktree we already verified
        // clean (or were force-removing anyway), and `git worktree remove` would
        // otherwise refuse the now-modified checkout.
        if force || ranTeardown { arguments.append("--force") }
        arguments.append(worktree.path)
        try await runGit(in: project.rootPath, arguments, commandLabel: "worktree remove")
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
    /// and never blocks removal.
    /// - Returns: `true` when a teardown script was actually launched (so the
    ///   caller forces removal, since the script may have dirtied the checkout);
    ///   `false` when there was nothing to run.
    private func runTeardownIfNeeded(worktree: SupermuxProjectWorktree, project: SupermuxProject) async -> Bool {
        guard let body = SupermuxWorktreeScript.joined(project.teardownCommands) else { return false }
        guard FileManager.default.fileExists(atPath: worktree.path) else { return false }
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
        return true
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
        let existing = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
        guard !existing.components(separatedBy: .newlines).contains(pattern) else { return }
        try? FileManager.default.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
        let updated = existing.isEmpty ? pattern + "\n" : existing.trimmingCharacters(in: .newlines) + "\n" + pattern + "\n"
        try? updated.write(toFile: excludePath, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func runGit(in directory: String, _ arguments: [String], commandLabel: String) async throws -> CommandResult {
        let result = await runner.run(
            directory: directory,
            executable: "git",
            arguments: arguments,
            timeout: Self.gitTimeout
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

    private static func normalizedPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast())
            : standardized
    }
}

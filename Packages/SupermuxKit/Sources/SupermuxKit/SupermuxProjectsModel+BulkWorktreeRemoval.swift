public import Foundation

/// Outcome of removing several worktrees in one pass
/// (``SupermuxProjectsModel/removeWorktrees(_:projectId:force:deleteBranch:)``).
///
/// Removal is per-worktree and never aborts early: one dirty or failing
/// checkout must not leave the rest behind. Callers read the three buckets to
/// decide what to show and whether to offer a forced retry for `dirty`.
public struct SupermuxWorktreeBulkRemovalResult: Sendable {
    /// One worktree whose removal failed for a reason other than uncommitted
    /// changes (unmanaged, git failure, …).
    public struct Failure: Sendable {
        /// The worktree that could not be removed.
        public let worktree: SupermuxProjectWorktree
        /// Why removal failed (a ``SupermuxGitError`` from the service).
        public let error: any Error

        /// Memberwise initializer.
        public init(worktree: SupermuxProjectWorktree, error: any Error) {
            self.worktree = worktree
            self.error = error
        }
    }

    /// Worktrees that were removed.
    public var removed: [SupermuxProjectWorktree] = []
    /// Worktrees skipped because they have uncommitted changes. Only populated
    /// when `force` was `false`; retry these with `force: true` after the user
    /// acknowledges the loss.
    public var dirty: [SupermuxProjectWorktree] = []
    /// Worktrees whose removal failed terminally.
    public var failures: [Failure] = []

    /// An empty result.
    public init() {}
}

extension SupermuxProjectsModel {
    /// Removes every supermux-managed worktree of a project (the project row's
    /// "Delete All Worktrees…").
    ///
    /// Refreshes the worktree list first so a stale sidebar snapshot can never
    /// pick the set; worktrees supermux does not manage are left alone rather
    /// than reported as failures. Dirty checkouts are skipped and returned in
    /// ``SupermuxWorktreeBulkRemovalResult/dirty`` — pass them back through
    /// ``removeWorktrees(_:projectId:force:deleteBranch:)`` with `force: true`
    /// once the user has confirmed.
    /// - Parameters:
    ///   - projectId: Owning project.
    ///   - deleteBranch: Also delete each worktree's local branch.
    /// - Returns: What was removed, what was kept dirty, and what failed.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when the
    ///   worktrees cannot be listed. The plain ``refreshWorktrees(for:)`` clears
    ///   the cached list to `[]` on failure, which would turn a destructive
    ///   action the user just confirmed into a silent no-op — so this uses the
    ///   success-reporting refresh and fails loudly instead, deleting nothing.
    public func removeAllWorktrees(projectId: UUID, deleteBranch: Bool) async throws -> SupermuxWorktreeBulkRemovalResult {
        guard await refreshWorktreesReportingSuccess(for: projectId) else {
            throw SupermuxGitError.gitFailed(
                command: "git worktree list",
                message: String(
                    localized: "supermux.worktree.deleteAll.listFailed",
                    defaultValue: "The project’s worktrees could not be listed. Nothing was deleted."
                )
            )
        }
        let managed = (worktreesByProjectId[projectId] ?? []).filter(\.isSupermuxManaged)
        return await removeWorktrees(managed, projectId: projectId, force: false, deleteBranch: deleteBranch)
    }

    /// Removes the given worktrees one after another through the single
    /// ``removeWorktree(_:projectId:force:deleteBranch:)`` path (dirty guard,
    /// teardown script, git-native removal, list refresh), bucketing each
    /// outcome instead of throwing on the first problem.
    ///
    /// Sequential on purpose: teardown scripts and `git worktree remove` both
    /// take repository locks, and a user reading a failure list expects it to
    /// be in the order the worktrees were shown.
    /// - Parameters:
    ///   - worktrees: Worktrees to remove.
    ///   - projectId: Owning project.
    ///   - force: Remove despite uncommitted changes.
    ///   - deleteBranch: Also delete each worktree's local branch.
    /// - Returns: What was removed, what was kept dirty, and what failed.
    public func removeWorktrees(
        _ worktrees: [SupermuxProjectWorktree],
        projectId: UUID,
        force: Bool,
        deleteBranch: Bool
    ) async -> SupermuxWorktreeBulkRemovalResult {
        var result = SupermuxWorktreeBulkRemovalResult()
        for worktree in worktrees {
            do {
                try await removeWorktree(worktree, projectId: projectId, force: force, deleteBranch: deleteBranch)
                result.removed.append(worktree)
            } catch SupermuxGitError.dirtyWorktree {
                result.dirty.append(worktree)
            } catch {
                result.failures.append(.init(worktree: worktree, error: error))
            }
        }
        return result
    }
}

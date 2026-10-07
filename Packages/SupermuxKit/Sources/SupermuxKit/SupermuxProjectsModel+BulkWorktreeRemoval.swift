public import Foundation

/// Outcome of removing several worktrees in one pass, on this Mac
/// (``SupermuxProjectsModel/removeWorktrees(_:projectId:force:deleteBranch:)``)
/// or on another one (the host's remote worktree commands).
///
/// Removal is per-worktree and never aborts early: one dirty or failing
/// checkout must not leave the rest behind. Callers read the three buckets to
/// decide what to show and whether to offer a forced retry for `dirty`.
public struct SupermuxWorktreeBulkRemovalResult<Worktree: Sendable>: Sendable {
    /// One worktree whose removal failed for a reason other than uncommitted
    /// changes (git failure, unreachable Mac, …).
    public struct Failure: Sendable {
        /// The worktree that could not be removed.
        public let worktree: Worktree
        /// Why removal failed.
        public let error: any Error

        /// Memberwise initializer.
        public init(worktree: Worktree, error: any Error) {
            self.worktree = worktree
            self.error = error
        }
    }

    /// Worktrees that were removed.
    public var removed: [Worktree] = []
    /// Worktrees skipped because they have uncommitted changes. Only populated
    /// when `force` was `false`; retry these with `force: true` after the user
    /// acknowledges the loss.
    public var dirty: [Worktree] = []
    /// Worktrees whose removal failed terminally.
    public var failures: [Failure] = []

    /// An empty result.
    public init() {}

    /// Removes `worktrees` one after another with `remove`, deepest folder
    /// first, bucketing each outcome instead of throwing on the first problem.
    ///
    /// Removing a worktree deletes its whole folder, worktrees nested inside it
    /// included, and its dirty check never sees a nested one in a git-ignored
    /// folder (`.worktrees`, `.claude/worktrees`). So nested worktrees go
    /// first, and a worktree holding one that was kept is kept too: as dirty
    /// when the nested one is (Delete Anyway removes both, deepest first), as
    /// failed when the nested one failed. Sequential on purpose: teardown
    /// scripts and `git worktree remove` both take repository locks.
    /// - Parameters:
    ///   - worktrees: Worktrees to remove.
    ///   - path: A worktree's absolute folder.
    ///   - isDirty: Whether an error `remove` threw means "has uncommitted changes".
    ///   - remove: Removes one worktree (the single per-worktree path).
    @MainActor
    public static func removing(
        _ worktrees: [Worktree],
        path: (Worktree) -> String,
        isDirty: (any Error) -> Bool,
        remove: (Worktree) async throws -> Void
    ) async -> Self {
        var result = Self()
        var keptDirty: [String] = []
        var keptFailed: [String] = []
        for worktree in worktrees.sorted(by: { path($0).count > path($1).count }) {
            let folder = path(worktree)
            let holds = { (kept: [String]) in kept.contains { $0.hasPrefix(folder + "/") } }
            if holds(keptFailed) {
                result.failures.append(Failure(worktree: worktree, error: SupermuxNestedWorktreeKeptError()))
                keptFailed.append(folder)
                continue
            }
            if holds(keptDirty) {
                result.dirty.append(worktree)
                keptDirty.append(folder)
                continue
            }
            do {
                try await remove(worktree)
                result.removed.append(worktree)
            } catch where isDirty(error) {
                result.dirty.append(worktree)
                keptDirty.append(folder)
            } catch {
                result.failures.append(Failure(worktree: worktree, error: error))
                keptFailed.append(folder)
            }
        }
        return result
    }
}

/// A worktree kept because a worktree inside its folder could not be removed
/// (removing the outer one would delete the inner one's files).
public struct SupermuxNestedWorktreeKeptError: LocalizedError {
    public var errorDescription: String? {
        String(
            localized: "supermux.worktree.deleteAll.nestedKept",
            defaultValue: "A worktree inside it couldn’t be deleted, so it was kept."
        )
    }
}

extension SupermuxProjectsModel {
    /// Removes every worktree of a project on this Mac (the project row's
    /// "Delete All Worktrees…"), wherever it lives on disk.
    ///
    /// Refreshes the worktree list first so a stale sidebar snapshot can never
    /// pick the set. Dirty checkouts are skipped and returned in
    /// ``SupermuxWorktreeBulkRemovalResult/dirty`` — pass them back through
    /// ``removeWorktrees(_:projectId:force:deleteBranch:)`` with `force: true`
    /// once the user has confirmed.
    /// - Parameters:
    ///   - projectId: Owning project.
    ///   - deleteBranch: Also delete each worktree's local branch.
    /// - Returns: What was removed, what was kept dirty, and what failed.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when the
    ///   worktrees cannot be listed (see ``worktreesForRemoval(projectId:)``).
    public func removeAllWorktrees(
        projectId: UUID,
        deleteBranch: Bool
    ) async throws -> SupermuxWorktreeBulkRemovalResult<SupermuxProjectWorktree> {
        let worktrees = try await worktreesForRemoval(projectId: projectId)
        return await removeWorktrees(worktrees, projectId: projectId, force: false, deleteBranch: deleteBranch)
    }

    /// "Delete All Worktrees" of a project on this Mac: the shared flow over
    /// ``worktreesForRemoval(projectId:)`` and
    /// ``removeWorktrees(_:projectId:force:deleteBranch:)``.
    public func deleteAllWorktreesFlow(projectId: UUID) -> SupermuxDeleteAllWorktreesFlow<SupermuxProjectWorktree> {
        SupermuxDeleteAllWorktreesFlow(
            list: { try await self.worktreesForRemoval(projectId: projectId) },
            remove: { batch, force, deleteBranches in
                await self.removeWorktrees(batch, projectId: projectId, force: force, deleteBranch: deleteBranches)
            }
        )
    }

    /// Re-lists the project's worktrees from git: the exact set a Delete All
    /// acts on. Every linked worktree counts, made by supermux or not; the main
    /// checkout is never listed (see ``SupermuxGitWorktreeService/listWorktrees(for:)``),
    /// nor a worktree whose folder holds the project's own checkout.
    ///
    /// The sidebar calls this *before* showing its confirmation so the list the
    /// user confirms is the list that gets deleted (then passes it to
    /// ``removeWorktrees(_:projectId:force:deleteBranch:)``), rather than
    /// confirming a cached snapshot and deleting a refreshed one.
    /// - Parameter projectId: Owning project.
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git
    ///   cannot list the worktrees; the cached list is left untouched. The plain
    ///   ``refreshWorktrees(for:)`` clears it to `[]` on failure, which would turn
    ///   a destructive action the user just confirmed into a silent no-op.
    public func worktreesForRemoval(projectId: UUID) async throws -> [SupermuxProjectWorktree] {
        guard await refreshWorktreesReportingSuccess(for: projectId) else {
            throw SupermuxGitError.gitFailed(
                command: "worktree list",
                message: String(
                    localized: "supermux.worktree.deleteAll.listFailed",
                    defaultValue: "The project’s worktrees could not be listed. Nothing was deleted."
                )
            )
        }
        // A worktree holding the project's own checkout (a project registered
        // at a worktree nested in another) would take the project with it.
        let root = SupermuxWorktreePath.canonical(projects.first { $0.id == projectId }?.rootPath ?? "")
        return (worktreesByProjectId[projectId] ?? []).filter { !root.hasPrefix($0.path + "/") }
    }

    /// Removes the given worktrees one after another (nested ones first, see
    /// ``SupermuxWorktreeBulkRemovalResult/removing(_:path:isDirty:remove:)``) through the single
    /// ``removeWorktree(_:projectId:force:deleteBranch:)`` path (dirty guard,
    /// teardown script, git-native removal, list refresh), bucketing each
    /// outcome instead of throwing on the first problem.
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
    ) async -> SupermuxWorktreeBulkRemovalResult<SupermuxProjectWorktree> {
        await .removing(worktrees, path: \.path, isDirty: SupermuxGitError.isDirtyWorktree) { worktree in
            try await removeWorktree(worktree, projectId: projectId, force: force, deleteBranch: deleteBranch)
        }
    }
}

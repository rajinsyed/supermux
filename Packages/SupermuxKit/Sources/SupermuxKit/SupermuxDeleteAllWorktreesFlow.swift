/// "Delete All Worktrees" for one Mac's copy of a project: list that Mac's
/// worktrees afresh, ask, delete exactly the listed set, then ask again
/// before forcing the ones kept back for uncommitted changes.
///
/// One path for every Mac and every entry point: the sidebar answers the two
/// questions with alerts (`runWithAlerts`), the DEBUG socket with its params.
/// This Mac plugs in ``SupermuxProjectsModel``; another Mac plugs in the
/// host's device-link commands.
///
/// ```swift
/// let flow = SupermuxDeleteAllWorktreesFlow(
///     list: { try await model.worktreesForRemoval(projectId: id) },
///     remove: { batch, force, deleteBranches in
///         await model.removeWorktrees(batch, projectId: id, force: force, deleteBranch: deleteBranches)
///     }
/// )
/// let outcome = try await flow.run(confirm: { _ in false }, confirmForce: { _ in false })
/// ```
@MainActor
public struct SupermuxDeleteAllWorktreesFlow<Worktree: Sendable> {
    /// What one run did.
    public struct Outcome: Sendable {
        /// The worktrees listed and confirmed (empty: there was nothing to delete).
        public let listed: [Worktree]
        /// What was removed, kept dirty (Delete Anyway declined) and failed.
        public let result: SupermuxWorktreeBulkRemovalResult<Worktree>
    }

    /// Lists every worktree to delete, afresh. Throws when the Mac cannot
    /// list them, so a stale list is never acted on.
    private let list: @MainActor () async throws -> [Worktree]
    /// Removes a batch `(worktrees, force, deleteBranches)`.
    private let remove: @MainActor ([Worktree], Bool, Bool) async -> SupermuxWorktreeBulkRemovalResult<Worktree>

    /// Creates the flow for one Mac's copy of a project.
    /// - Parameters:
    ///   - list: Lists that copy's worktrees afresh (never the main checkout).
    ///   - remove: Removes a batch `(worktrees, force, deleteBranches)`.
    public init(
        list: @escaping @MainActor () async throws -> [Worktree],
        remove: @escaping @MainActor ([Worktree], Bool, Bool) async -> SupermuxWorktreeBulkRemovalResult<Worktree>
    ) {
        self.list = list
        self.remove = remove
    }

    /// Runs the flow.
    /// - Parameters:
    ///   - confirm: Asked with the listed worktrees (never empty): `nil`
    ///     cancels, otherwise whether to delete their local branches too.
    ///   - confirmForce: Asked with the worktrees kept for uncommitted
    ///     changes: whether to delete them anyway.
    /// - Returns: What happened, or `nil` when the user cancelled.
    /// - Throws: When the worktrees cannot be listed; nothing is deleted.
    public func run(
        confirm: ([Worktree]) -> Bool?,
        confirmForce: ([Worktree]) -> Bool
    ) async throws -> Outcome? {
        let worktrees = try await list()
        guard !worktrees.isEmpty else { return Outcome(listed: [], result: .init()) }
        guard let deleteBranches = confirm(worktrees) else { return nil }
        var result = await remove(worktrees, false, deleteBranches)
        if !result.dirty.isEmpty, confirmForce(result.dirty) {
            let forced = await remove(result.dirty, true, deleteBranches)
            result.removed += forced.removed
            result.failures += forced.failures
            result.dirty = forced.dirty
        }
        return Outcome(listed: worktrees, result: result)
    }
}

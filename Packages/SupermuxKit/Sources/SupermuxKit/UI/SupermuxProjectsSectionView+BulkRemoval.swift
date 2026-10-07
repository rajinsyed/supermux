import SwiftUI

/// The project row's "Delete All Worktrees…" on this Mac: the shared
/// ``SupermuxDeleteAllWorktreesFlow`` over the projects model, behind the
/// sidebar's alerts. Another Mac's copy goes through
/// ``SupermuxRemoteProjectActions/removeAllWorktrees``.
extension SupermuxProjectsSectionView {
    /// Entry point wired to ``SupermuxProjectRowActions/deleteAllWorktrees``.
    @MainActor
    func deleteAllWorktrees(project: SupermuxProject) {
        let flow = model.deleteAllWorktreesFlow(projectId: project.id)
        Task {
            await flow.runWithAlerts(projectName: project.name, macName: nil, displayName: \.displayName)
        }
    }
}

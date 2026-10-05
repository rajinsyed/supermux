import Foundation
import SupermuxKit

/// The rows the Projects section nests under projects, for one window: one
/// snapshot per workspace (full for project-owned rows, the cheap standalone
/// one for the rest), in the order the section shows them. The mount renders
/// exactly this list and `supermux.devices.sidebar_rows` reports it, so an
/// E2E test sees what the sidebar draws.
@MainActor
enum SupermuxNestedWorkspaceRows {
    /// The window's rows.
    /// - Parameters:
    ///   - tabManager: The window.
    ///   - includePullRequest: Whether PR badges show (cmux's PR polling gates).
    ///   - unreadCount: The displayed unread count of a workspace.
    static func rows(
        for tabManager: TabManager,
        includePullRequest: Bool,
        unreadCount: (UUID) -> Int
    ) -> [SupermuxOpenWorkspace] {
        let projects = SupermuxComposition.projectsModel.projects
        let associations = SupermuxComposition.workspaceAssociations
        // This window's memoized project resolution — the same cache instance
        // the flat-list filter uses, so per-workspace NSString path
        // normalization runs once per invalidation, not once per consumer.
        // Its validity preamble reads the store's observable `revision` and
        // durable directory map on every call (cache hits included), which is
        // what re-renders the mount on association changes.
        let resolutionCache = SupermuxMainListFilter.resolutionCache(for: tabManager)
        // Device mirrors nest by their remote record's project (never by
        // local path); reading it here re-renders on ownership changes. A
        // nested mirror's record fields (branch, PR) re-render it through
        // the unified model's `mirrorRemoteFields`, and its activity through
        // the status projector's lifecycle relay, so this body follows no
        // device revision.
        let ownership = SupermuxMirrorOwnership.current()
        let rows = tabManager.tabs.map { workspace -> SupermuxOpenWorkspace in
            let isSelected = workspace.id == tabManager.selectedTabId
            // Full snapshots (branch/PR/activity, each walking the bonsplit
            // pane tree) only for project-nested rows; the section consumes
            // just the directory of everything else.
            guard let projectId = resolutionCache.projectId(
                forWorkspace: workspace,
                projects: projects,
                associations: associations,
                ownership: ownership
            ) else {
                return SupermuxWorkspaceRow.standaloneSnapshot(
                    for: workspace,
                    isSelected: isSelected,
                    isMirror: ownership.isMirror(workspace)
                )
            }
            if ownership.isMirror(workspace) {
                return SupermuxMirrorRowSnapshot.snapshot(
                    for: workspace,
                    isSelected: isSelected,
                    projectId: projectId,
                    includePullRequest: includePullRequest,
                    unreadCount: unreadCount(workspace.id)
                )
            }
            return SupermuxWorkspaceRow.snapshot(
                for: workspace,
                isSelected: isSelected,
                projectId: projectId,
                isRunning: SupermuxComposition.runCoordinator.isRunning(workspaceId: workspace.id),
                includePullRequest: includePullRequest,
                unreadCount: unreadCount(workspace.id)
            )
        }
        // Inside a project: this Mac's workspaces first (tab order), then each
        // Mac's mirrors as one group (device order; auto-mirror keeps each
        // group in that Mac's own order). Rows outside projects keep their place.
        return SupermuxNestedWorkspaceOrder.sorted(
            rows,
            deviceOrder: SupermuxComposition.devices.devices.map(\.machine.rawValue)
        )
    }
}

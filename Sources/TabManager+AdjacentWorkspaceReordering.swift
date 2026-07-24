import Foundation

/// Shared adjacent workspace-reorder entrypoints for shortcuts, menus, and automation.
extension TabManager {
    /// Reorders one workspace by a relative offset. The existing coordinator
    /// clamps the result to the workspace's pinned or unpinned tier.
    @discardableResult
    func reorderWorkspace(tabId: UUID, by offset: Int) -> Bool {
        // SUPERMUX:begin sidebar-hide-project-workspaces
        // Step over project-hidden rows so every adjacent-move entrypoint
        // (context menu, shortcut, socket verbs) swaps with the nearest
        // *visible* flat-list neighbor; moves whose clamped destination would
        // not change the visible order are refused. See
        // `supermuxSteppedReorderTarget` in
        // `Sources/Supermux/SupermuxWorkspaceReorderStepping.swift`.
        // (upstream:
        //   guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        //   return reorderWorkspace(tabId: tabId, toIndex: currentIndex + offset))
        guard let targetIndex = supermuxSteppedReorderTarget(tabId: tabId, by: offset) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: targetIndex)
        // SUPERMUX:end sidebar-hide-project-workspaces
    }

    /// Reorders the selected workspace while preserving its selection.
    @discardableResult
    func moveSelectedWorkspace(by offset: Int) -> Bool {
        guard let workspace = selectedWorkspace,
              reorderWorkspace(tabId: workspace.id, by: offset) else { return false }
        selectWorkspace(workspace)
        return true
    }
}

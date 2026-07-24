import Foundation

/// Hidden-row-aware planning for adjacent workspace moves (Move Up / Move
/// Down), shared by every entrypoint: the sidebar context menu, the
/// menu-bar/keyboard shortcut (`moveSelectedWorkspace`), and the socket
/// `workspace.action move_up`/`move_down` verbs — all of which route through
/// `TabManager.reorderWorkspace(tabId:by:)`.
///
/// Project-owned workspaces are hidden from the flat sidebar list (they render
/// nested in the Projects section) but stay in `TabManager.tabs`, so upstream's
/// plain `currentIndex + offset` would swap a visible row with an invisible
/// hidden neighbor: the sidebar wouldn't change and the command would appear
/// broken. Stepping walks past hidden rows to the nearest *visible* slot, and
/// a move whose clamped destination (pin tier / group section — see
/// `WorkspacesModel.clampedReorderIndex`) would not change the visible order
/// is refused outright rather than invisibly reshuffling hidden rows.
extension TabManager {
    /// The target index for moving `tabId` by `offset` visible rows, or `nil`
    /// when no such move exists (unknown id, or the clamped destination leaves
    /// the visible flat-list order unchanged). A `nil` also drives the context
    /// menu's Move Up/Down enablement, keeping the menu and the mutation in
    /// agreement. Hidden workspaces themselves (moved programmatically via the
    /// socket) keep upstream's plain adjacent semantics.
    func supermuxSteppedReorderTarget(tabId: UUID, by offset: Int) -> Int? {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let hiddenIds = SupermuxMainListFilter.projectHiddenWorkspaceIds(tabs, tabManager: self)
        guard !hiddenIds.isEmpty, !hiddenIds.contains(tabId) else {
            return currentIndex + offset
        }
        let step = offset > 0 ? 1 : -1
        var remaining = abs(offset)
        var targetIndex = currentIndex
        while remaining > 0 {
            targetIndex += step
            guard targetIndex >= 0, targetIndex < tabs.count else { break }
            if !hiddenIds.contains(tabs[targetIndex].id) { remaining -= 1 }
        }
        targetIndex = max(0, min(targetIndex, tabs.count - 1))
        // The coordinator clamps to the workspace's legal range (pin tier,
        // group section); a clamp can pull the stepped target back onto a
        // hidden row's slot. Project the post-move order and refuse moves
        // that leave the visible sequence untouched.
        guard let plan = workspaceReordering.workspaceReorderPlan(tabId: tabId, toIndex: targetIndex),
              plan.fromIndex != plan.toIndex else { return nil }
        var projected = tabs.map(\.id)
        let movedId = projected.remove(at: plan.fromIndex)
        projected.insert(movedId, at: plan.toIndex)
        let visibleBefore = tabs.compactMap { hiddenIds.contains($0.id) ? nil : $0.id }
        let visibleAfter = projected.filter { !hiddenIds.contains($0) }
        guard visibleAfter != visibleBefore else { return nil }
        return targetIndex
    }
}

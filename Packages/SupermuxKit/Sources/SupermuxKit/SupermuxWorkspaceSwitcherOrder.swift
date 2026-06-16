public import Foundation

/// Pure ordering logic for the workspace switcher: most-recently-used (MRU)
/// bookkeeping, the frozen per-session order, and selection-index arithmetic.
///
/// All functions are value-in / value-out so the behavior that defines the
/// switcher's "feel" (hold Cmd, a quick tap toggles the two most-recent
/// workspaces; the strip never reshuffles mid-cycle) is unit-testable without
/// AppKit. The host keeps an `[UUID]` MRU list per `TabManager` and feeds it
/// here; the controller calls ``sessionOrder(currentId:mru:tabsOrder:)`` once at
/// present time and freezes the result.
public enum SupermuxWorkspaceSwitcherOrder {
    /// Moves `id` to the front of the MRU list (inserting it when absent),
    /// preserving the relative order of the rest. Called whenever the active
    /// workspace changes.
    public static func promote(_ id: UUID, in mru: [UUID]) -> [UUID] {
        var result = mru
        result.removeAll { $0 == id }
        result.insert(id, at: 0)
        return result
    }

    /// Drops any MRU entries whose workspace no longer exists, keeping order.
    /// Called when the open-workspace set changes so a closed workspace never
    /// lingers in the recency list.
    public static func pruned(_ mru: [UUID], keeping liveIds: Set<UUID>) -> [UUID] {
        mru.filter { liveIds.contains($0) }
    }

    /// The frozen order shown in the switcher for one hold session.
    ///
    /// Layout: the current workspace first (index 0), then the remaining
    /// workspaces in MRU order, then any open workspaces not yet seen in the MRU
    /// list appended in their natural `tabsOrder`. Only ids present in
    /// `tabsOrder` are included, so the result is always a permutation of the
    /// live open workspaces.
    public static func sessionOrder(
        currentId: UUID?,
        mru: [UUID],
        tabsOrder: [UUID]
    ) -> [UUID] {
        let live = Set(tabsOrder)
        var result: [UUID] = []
        var seen = Set<UUID>()

        func append(_ id: UUID) {
            guard live.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }

        if let currentId { append(currentId) }
        for id in mru { append(id) }
        for id in tabsOrder { append(id) }
        return result
    }

    /// The initially highlighted index when the switcher opens.
    ///
    /// Forward (Cmd+`): the previous workspace (index 1), mirroring the macOS app
    /// switcher; falls back to index 0 when only one workspace exists. Backward
    /// (Shift+Cmd+`): the last item (wrap to the most distant), or 0 for one item.
    public static func initialSelection(count: Int, backward: Bool) -> Int {
        guard count > 1 else { return 0 }
        return backward ? count - 1 : 1
    }

    /// Advances the highlighted index by one step with wraparound. Returns 0 for
    /// an empty list.
    public static func advance(_ index: Int, count: Int, backward: Bool) -> Int {
        guard count > 0 else { return 0 }
        let delta = backward ? -1 : 1
        return ((index + delta) % count + count) % count
    }
}

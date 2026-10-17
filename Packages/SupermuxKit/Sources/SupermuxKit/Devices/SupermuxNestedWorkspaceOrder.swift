public import Foundation

/// The order of the workspaces nested under one project in the sidebar:
/// every row in the shared order first, as one block, then the mirrors of
/// each older Mac (whose workspaces carry no order key) as one block per Mac.
///
/// Stable: rows keep the order they arrive in (the window's tab order), so
/// only the blocks are imposed. The shared-order block needs nothing more:
/// apply has already placed every keyed mirror where its owner's key says,
/// so the tab order of this Mac's rows and keyed mirrors is the shared order,
/// and the pinned prefix stays first because the tabs lead with it. Inside an
/// older Mac's block auto-mirror keeps that Mac's own order.
public enum SupermuxNestedWorkspaceOrder {
    /// `workspaces` in blocks by ``SupermuxOpenWorkspace/orderGroup``: the
    /// shared-order rows (``SupermuxOpenWorkspace/orderedGroup``) first, then
    /// each older Mac's mirrors in `deviceOrder` (machine ids), then Macs
    /// missing from it in the order they first appear.
    public static func sorted(_ workspaces: [SupermuxOpenWorkspace], deviceOrder: [String]) -> [SupermuxOpenWorkspace] {
        var rankByGroup = [SupermuxOpenWorkspace.orderedGroup: 0]
        for group in deviceOrder + workspaces.map(\.orderGroup) where rankByGroup[group] == nil {
            rankByGroup[group] = rankByGroup.count
        }
        func rank(_ workspace: SupermuxOpenWorkspace) -> Int {
            rankByGroup[workspace.orderGroup] ?? 0
        }
        return workspaces.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (rank(lhs.element), rank(rhs.element))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

public import Foundation

/// The order of the workspaces nested under one project in the sidebar:
/// this Mac's own workspaces first, then each other Mac's mirrors as one
/// group per Mac.
///
/// Stable: inside a group rows keep the order they arrive in (the window's
/// tab order, which auto-mirror keeps in each Mac's own order and a drag
/// within the group changes), so only the grouping is imposed.
public enum SupermuxNestedWorkspaceOrder {
    /// `workspaces` grouped: this Mac's first, then the mirrors of each Mac in
    /// `deviceOrder` (machine ids), then Macs missing from it in the order
    /// they first appear.
    public static func sorted(_ workspaces: [SupermuxOpenWorkspace], deviceOrder: [String]) -> [SupermuxOpenWorkspace] {
        var rankByMachine: [String: Int] = [:]
        for machine in deviceOrder + workspaces.compactMap(\.device?.machineID) where rankByMachine[machine] == nil {
            rankByMachine[machine] = rankByMachine.count
        }
        func rank(_ workspace: SupermuxOpenWorkspace) -> Int {
            workspace.device.flatMap { rankByMachine[$0.machineID] } ?? -1
        }
        return workspaces.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (rank(lhs.element), rank(rhs.element))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

// SUPERMUX:begin supermux-mobile-nested-reorder (whole file: sends a nested project row's drag to its Mac — see SUPERMUX-TOUCHPOINTS.md)
#if os(iOS)
import CmuxMobileShellModel
import SupermuxMobileUI

extension WorkspaceListView {
    /// Sends a drag of a row nested under a project to the row's Mac as one
    /// `workspace.move`, through the same `moveWorkspace` path the loose rows
    /// use, and shows the new order until the Mac's list comes back. `nil`
    /// (no nested drag) when the host cannot move workspaces or the list
    /// sorts by recent activity, whose order has no place on the Mac.
    ///
    /// The anchor is worked out when the move is sent, after every earlier
    /// move came back, so it reads the Mac's current order. The shown order
    /// ends once the list holds the move: a background Mac's list is fetched
    /// again only after the move answered (at most a few seconds). A move the
    /// Mac refused or the list never showed counts as not landed.
    var supermuxMoveNestedWorkspace: (@MainActor (SupermuxNestedMove) -> Void)? {
        guard let moveWorkspace, !appliesRecencySort else { return nil }
        let reorder = supermuxProjects.nestedReorder
        let store = store
        let listed = workspaces
        return { move in
            reorder.perform(move) {
                let current = store?.workspaces ?? listed
                let before = SupermuxNestedReorderPolicy().beforeWorkspaceID(for: move, in: current)
                // The row keeps its group: a `nil` group asks the Mac to ungroup it.
                let groupID = current.first { $0.id == move.workspaceID }?.groupID
                guard await moveWorkspace(move.workspaceID, groupID, before, false) else { return false }
                guard let store else { return true }
                return await SupermuxNestedReorderModel.wait(upTo: .seconds(3)) {
                    SupermuxNestedReorderPolicy().listHolds(move, store.workspaces)
                }
            }
        }
    }
}
#endif
// SUPERMUX:end supermux-mobile-nested-reorder

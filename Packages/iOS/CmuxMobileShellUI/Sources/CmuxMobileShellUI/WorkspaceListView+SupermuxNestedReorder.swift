// SUPERMUX:begin supermux-mobile-nested-reorder (whole file: sends a nested project row's drag to its Mac — see SUPERMUX-TOUCHPOINTS.md)
#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import SupermuxMobileUI

/// The shell store already has the rows and the per-Mac refresh a nested
/// drag needs.
extension MobileShellComposite: @retroactive SupermuxWorkspaceShell {}

extension WorkspaceListView {
    /// Sends a drag of a row nested under a project to the Mac that owns it,
    /// and shows the new order until the Mac's list comes back. `nil` (no
    /// nested drag) when the host cannot move workspaces or the list sorts
    /// by recent activity, whose order has no place on the Mac.
    ///
    /// A row with a shared order key moves among every Mac's keyed rows: the
    /// drop is sent to its owner as a new key
    /// (`mobile.supermux.workspace.set_order`, through
    /// `SupermuxProjectsSectionModel.landOrderedMove`), and the move holds
    /// once the key-sorted list shows it. Any other row moves inside its own
    /// Mac's window as ONE `workspace.move`, through the same `moveWorkspace`
    /// path the loose rows use.
    ///
    /// The key or anchor is worked out when the move is sent, after every
    /// earlier move came back, so it reads the Macs' current order. The shown
    /// order ends once the list holds the move: a background Mac's list is
    /// fetched again only after the move answered (at most a few seconds). A
    /// move the Mac refused or the list never showed counts as not landed.
    var supermuxMoveNestedWorkspace: (@MainActor (SupermuxNestedMove) -> Void)? {
        guard let moveWorkspace, !appliesRecencySort else { return nil }
        let reorder = supermuxProjects.nestedReorder
        let projects = supermuxProjects
        let store = store
        let listed = workspaces
        return { move in
            reorder.perform(move) {
                if SupermuxPhoneWorkspaceOrder().isOrdered(segment: move.segment) {
                    return await projects.landOrderedMove(move, shell: store, rows: listed)
                }
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

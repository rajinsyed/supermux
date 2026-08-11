#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// A row whose HEIGHT changes must keep its cell — and therefore everything
/// hosted inside it.
///
/// Every row in this table is a `UIHostingConfiguration`, and the fork's whole
/// Projects section is ONE such row. `reloadRows` hands back a different cell
/// instance, which destroys the hosted SwiftUI subtree along with its `@State`
/// and its `.task`s. That is invisible for a plain UIKit row and very visible
/// for a hosted one: an unrelated workspace growing a description line blanked
/// every project avatar (their decoded icons live in `@State`) and re-issued
/// their icon fetches over RPC.
///
/// `reconfigureRows(at:)` re-queries the height without replacing the cell,
/// which is what this path actually needs. These tests pin that, plus the one
/// case that still genuinely requires a reload.
@MainActor
@Suite struct WorkspaceListCellIdentityTests {
    /// The regression: a height change must not swap the cell out from under
    /// the hosted content.
    @Test func aHeightChangeKeepsTheSameCellInstance() {
        var workspace = preview(id: "workspace-1")
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration(workspaces: [workspace])
        )
        let tableView = makeTableView()
        coordinator.attach(to: tableView)
        tableView.layoutIfNeeded()

        let indexPath = IndexPath(row: 0, section: 0)
        let before = try? #require(tableView.cellForRow(at: indexPath))

        // A durable description adds a text line — the canonical height change.
        workspace.customDescription = "Durable workspace context"
        coordinator.update(configuration: configuration(workspaces: [workspace]), in: tableView)
        tableView.layoutIfNeeded()

        let after = tableView.cellForRow(at: indexPath)
        #expect(
            before === after,
            "A height change must reconfigure the row, not replace its cell — replacing it destroys the hosted SwiftUI state."
        )
    }

    /// The reconfigure must still let UIKit re-measure, or the row would keep
    /// its old height and clip the new line.
    @Test func aHeightChangeStillReQueriesTheRowHeight() {
        var workspace = preview(id: "workspace-1")
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration(workspaces: [workspace])
        )
        let tableView = makeTableView()
        coordinator.attach(to: tableView)
        tableView.layoutIfNeeded()

        let indexPath = IndexPath(row: 0, section: 0)
        let heightBefore = tableView.rectForRow(at: indexPath).height

        workspace.customDescription = "Durable workspace context"
        coordinator.update(configuration: configuration(workspaces: [workspace]), in: tableView)
        tableView.layoutIfNeeded()

        let heightAfter = tableView.rectForRow(at: indexPath).height
        #expect(
            heightAfter > heightBefore,
            "Reconfiguring must not skip the height re-query; the added description line has to change the row height."
        )
    }

    /// The exception. UIKit caches swipe-derived accessibility actions on the
    /// cell, and reconfiguring does not invalidate that cache — so a row whose
    /// native actions changed still has to reload.
    @Test func aNativeActionChangeStillReloadsTheRow() {
        let workspace = preview(id: "workspace-1")
        // Read-state actions are what put a leading swipe on the row, so
        // toggling unread changes the row's native action payload.
        let capable = MobileWorkspaceActionCapabilities(supportsReadStateActions: true)
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration(
                workspaces: [workspace],
                actionCapabilities: capable,
                setUnread: { _, _ in }
            )
        )
        let tableView = makeTableView()
        coordinator.attach(to: tableView)
        tableView.layoutIfNeeded()

        var unread = workspace
        unread.hasUnread = true
        coordinator.update(
            configuration: configuration(
                workspaces: [unread],
                actionCapabilities: capable,
                setUnread: { _, _ in }
            ),
            in: tableView
        )

        #expect(
            coordinator.lastPayloadApplyRoute
                == WorkspaceListTableCoordinator.PayloadApplyRoute.tableReload
        )
    }

    // MARK: Helpers

    private func makeTableView() -> WorkspaceListUITableView {
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        // Cells only exist once the table is in a window and has laid out.
        let window = UIWindow(frame: tableView.frame)
        window.addSubview(tableView)
        window.isHidden = false
        return tableView
    }

    private func preview(id: String) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            previewText: "Build succeeded",
            terminals: []
        )
    }

    private func configuration(
        workspaces: [MobileWorkspacePreview],
        actionCapabilities: MobileWorkspaceActionCapabilities = .none,
        setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil
    ) -> WorkspaceListTable {
        let previews = workspaces.map { workspace -> MobileWorkspacePreview in
            var copy = workspace
            copy.actionCapabilities = actionCapabilities
            return copy
        }
        return WorkspaceListTable(
            items: previews.map { .workspace($0.id, indented: false) },
            workspacesByID: Dictionary(
                previews.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            groupsByID: [:],
            groupHasUnreadByID: [:],
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 1,
            unreadIndicatorLeftShift: 0,
            connectionStatus: .connected,
            workspaceChangesCapable: false,
            workspaceChangeChipsByWorkspaceID: [:],
            openWorkspaceChanges: nil,
            connectionRequiresReauth: false,
            connectionError: nil,
            host: "test-mac",
            isInitialConnectionLoading: false,
            initialConnectionTitle: nil,
            initialConnectionDescription: nil,
            enablesReorder: false,
            moveRows: nil,
            canDropIntoGroup: nil,
            dropIntoGroup: nil,
            selectWorkspace: { _ in },
            closeWorkspace: nil,
            setUnread: setUnread,
            setPinned: nil,
            renameRequest: nil,
            createWorkspaceInGroup: nil,
            renameWorkspaceGroup: nil,
            setGroupPinned: nil,
            ungroupWorkspaceGroup: nil,
            deleteWorkspaceGroup: nil,
            toggleGroupCollapsed: nil,
            showAll: {},
            signOut: nil,
            retryInitialConnection: nil,
            showAddDevice: nil,
            reconnect: nil,
            refresh: nil
        )
    }
}
#endif

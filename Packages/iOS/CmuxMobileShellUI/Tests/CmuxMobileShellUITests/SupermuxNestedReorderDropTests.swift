// SUPERMUX:begin supermux-mobile-nested-reorder (whole file: a fork test inside an upstream package — see SUPERMUX-TOUCHPOINTS.md)
#if os(iOS)
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import SupermuxMobileUI
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// Dragging a workspace nested under a project in the iPhone's table, through
/// the real coordinator's drag → drop proposal → perform drop flow against a
/// laid-out `UITableView` (XCUITest drags do not start a table drag on the
/// simulator). Failure modes, listed before the code:
///
/// 1. A nested row cannot be lifted at all (the round-4 rule), or only while
///    the loose list below happens to be reorderable (no loose rows, pinned
///    loose rows, several windows all turn that gate off).
/// 2. A nested row lifts with no way to send its move, on a Mac that cannot
///    move workspaces, or alone in its project (nothing to reorder).
/// 3. A drop outside the row's project (another project, a project row, the
///    loose list) is proposed as a move.
/// 4. The drop sends the wrong order, sends nothing, or goes down upstream's
///    loose-list path, which would move a loose workspace instead.
/// 5. A drop on the row's own place sends a move.
/// 6. Loose rows regress: one can drop into the nested rows, or its own
///    reorder stops reaching upstream's handler with the right indices.
/// 7. The table's drag interaction follows only the loose list's gate, so on a
///    Mac whose workspaces are all in projects no drag ever starts, although
///    the delegate would lift the row.
/// 8. Lifting a nested row lights up the loose groups' drop boundaries,
///    although it can never drop there.
@MainActor
@Suite struct SupermuxNestedReorderDropTests {
    private static var fixtureWindows: [UIWindow] = []

    private final class Recorder {
        var nestedMoves: [SupermuxNestedMove] = []
        var moveRowsCalls: [(IndexSet, Int)] = []
    }

    private let mac = SupermuxMacInfo(macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook", colorIndex: 0)

    private func workspace(_ id: String, project: String?, canMove: Bool = true) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: .init(rawValue: id), macDeviceID: mac.macDeviceID, windowID: "w1", name: id, terminals: [])
        workspace.macInstanceTag = mac.instanceTag
        workspace.supermuxProjectID = project
        workspace.actionCapabilities.supportsMoveActions = canMove
        return workspace
    }

    /// Rows: 0 PROJECTS, 1 #cmux, 2 a, 3 b, 4 c, 5 #infra, 6 x, 7 l1, 8 l2.
    private func makeFixture(
        recorder: Recorder,
        sendsNestedMoves: Bool = true,
        looseListReorders: Bool = false,
        bCanMove: Bool = true,
        looseGroup: Bool = false
    ) -> (coordinator: WorkspaceListTableCoordinator, tableView: WorkspaceListUITableView) {
        let workspaces = [
            workspace("a", project: "cmux"),
            workspace("b", project: "cmux", canMove: bCanMove),
            workspace("c", project: "cmux"),
            workspace("x", project: "infra"),
            workspace("l1", project: nil),
            workspace("l2", project: nil),
        ]
        let section = SupermuxProjectsSectionSnapshot(isCollapsed: false, groups: [
            SupermuxProjectsMacGroupSnapshot(
                header: SupermuxProjectsMacHeader(mac: mac),
                hasLoaded: true,
                rows: ["cmux", "infra"].map {
                    SupermuxProjectRowSnapshot(
                        project: SupermuxProjectDTO(id: $0, name: $0, rootPath: "/Users/dev/\($0)"),
                        pairingID: mac.pairingID)
                }),
        ])
        let layout = SupermuxProjectsListLayout(
            section: section,
            workspaces: workspaces,
            scope: SupermuxProjectsListScope(query: "", filter: .all, activeFilter: .all, appliesRecencySort: false),
            canEdit: false,
            preparingNewWorktreeProjectID: nil)
        let record: @MainActor (SupermuxNestedMove) -> Void = { recorder.nestedMoves.append($0) }
        let actions: SupermuxProjectsSectionActions = SupermuxProjectsSectionModel().actions
        let payload = SupermuxProjectsTablePayload(
            layout: layout,
            actions: actions,
            moveNestedWorkspace: sendsNestedMoves ? record : nil)
        let leadingRun: [WorkspaceListTableItem] = layout.entries.map { entry in
            switch entry {
            case .fork(let id): .chrome(.supermux(id))
            case .workspace(let id): .workspace(id, indented: true)
            }
        }
        // Rows 9–11 with `looseGroup`: a loose cmux group after the loose rows.
        let groupID = MobileWorkspaceGroupPreview.ID(rawValue: "group-g")
        var member = workspace("g1", project: nil)
        member.groupID = groupID
        let groupRows: [WorkspaceListTableItem] = looseGroup
            ? [.groupHeader(groupID), .workspace("g1", indented: true), .groupFooter(groupID)]
            : []
        let configuration = WorkspaceListTable(
            items: leadingRun + [.workspace("l1", indented: false), .workspace("l2", indented: false)] + groupRows,
            workspacesByID: Dictionary(uniqueKeysWithValues: (workspaces + [member]).map { ($0.id, $0) }),
            groupsByID: looseGroup ? [groupID: MobileWorkspaceGroupPreview(id: groupID, name: "G", anchorWorkspaceID: "g1")] : [:],
            groupUnreadByID: [:],
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 2,
            unreadIndicatorLeftShift: 0,
            unreadBadgeDiameter: 16,
            connectionStatus: .connected,
            workspaceChangesCapable: false,
            workspaceChangeChipsByWorkspaceID: [:],
            openWorkspaceChanges: nil,
            supermuxProjects: payload,
            connectionRequiresReauth: false,
            connectionError: nil,
            host: "Test Mac",
            isInitialConnectionLoading: false,
            initialConnectionTitle: nil,
            initialConnectionDescription: nil,
            enablesReorder: looseListReorders,
            moveRows: looseListReorders ? { recorder.moveRowsCalls.append(($0, $1)) } : nil,
            canDropIntoGroup: nil,
            dropIntoGroup: nil,
            selectWorkspace: { _ in },
            closeWorkspace: nil,
            setUnread: nil,
            setPinned: nil,
            renameRequest: nil,
            customizeRequest: nil,
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
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)
        let tableView = WorkspaceListUITableView(frame: CGRect(x: 0, y: 0, width: 390, height: 1400))
        let viewController = UIViewController()
        viewController.view.frame = tableView.frame
        viewController.view.addSubview(tableView)
        let window = UIWindow(frame: tableView.frame)
        window.rootViewController = viewController
        window.isHidden = false
        Self.fixtureWindows.append(window)
        coordinator.attach(to: tableView)
        tableView.layoutIfNeeded()
        return (coordinator, tableView)
    }

    private func liftedItems(_ fixture: (coordinator: WorkspaceListTableCoordinator, tableView: WorkspaceListUITableView), row: Int) -> [UIDragItem] {
        fixture.coordinator.tableView(
            fixture.tableView,
            itemsForBeginning: SupermuxFakeDragSession(),
            at: IndexPath(row: row, section: 0))
    }

    private func dragItem(_ id: String, indented: Bool = true) -> UIDragItem {
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = WorkspaceListTableItem.workspace(.init(rawValue: id), indented: indented)
        return item
    }

    private func proposal(
        _ fixture: (coordinator: WorkspaceListTableCoordinator, tableView: WorkspaceListUITableView),
        dragging item: UIDragItem,
        to row: Int
    ) -> (UITableViewDropProposal, SupermuxFakeDropSession) {
        let rect = fixture.tableView.rectForRow(at: IndexPath(row: min(row, 8), section: 0))
        let session = SupermuxFakeDropSession(dragItems: [item], location: CGPoint(x: rect.midX, y: rect.minY + 2))
        let proposal = fixture.coordinator.tableView(
            fixture.tableView,
            dropSessionDidUpdate: session,
            withDestinationIndexPath: IndexPath(row: row, section: 0))
        return (proposal, session)
    }

    private func drop(
        _ fixture: (coordinator: WorkspaceListTableCoordinator, tableView: WorkspaceListUITableView),
        dragging id: String,
        from source: Int,
        to destination: Int,
        indented: Bool = true
    ) -> SupermuxFakeDropCoordinator {
        let item = dragItem(id, indented: indented)
        let (proposal, session) = proposal(fixture, dragging: item, to: destination)
        let dropCoordinator = SupermuxFakeDropCoordinator(
            session: session,
            proposal: proposal,
            items: [SupermuxFakeDropItem(dragItem: item, sourceIndexPath: IndexPath(row: source, section: 0))],
            destinationIndexPath: IndexPath(row: destination, section: 0))
        fixture.coordinator.tableView(fixture.tableView, performDropWith: dropCoordinator)
        return dropCoordinator
    }

    // MARK: The table takes drags (7)

    @Test func theTableTakesDragsWhenOnlyNestedRowsCanMove() {
        let fixture = makeFixture(recorder: Recorder(), looseListReorders: false)
        #expect(fixture.tableView.dragInteractionEnabled)
        fixture.coordinator.update(configuration: fixture.coordinator.configuration, in: fixture.tableView)
        #expect(fixture.tableView.dragInteractionEnabled, "a list update turned the drag interaction off")
    }

    @Test func theTableTakesNoDragsWhenNothingCanMove() {
        let fixture = makeFixture(recorder: Recorder(), sendsNestedMoves: false, looseListReorders: false)
        #expect(!fixture.tableView.dragInteractionEnabled)
    }

    // MARK: Group boundaries (8)

    @Test func aNestedDragLeavesTheLooseGroupBoundariesAlone() {
        let fixture = makeFixture(recorder: Recorder(), looseListReorders: true, looseGroup: true)
        let footer = IndexPath(row: 11, section: 0)
        let idle = "MobileWorkspaceGroupFooterBoundary-group-g-inactive"
        fixture.tableView.scrollToRow(at: footer, at: .bottom, animated: false)
        fixture.tableView.layoutIfNeeded()
        #expect(fixture.tableView.cellForRow(at: footer)?.accessibilityIdentifier == idle)
        let nested = SupermuxFakeDragSession(dragItems: [dragItem("b")])
        fixture.coordinator.tableView(fixture.tableView, dragSessionWillBegin: nested)
        #expect(fixture.tableView.cellForRow(at: footer)?.accessibilityIdentifier == idle)
        fixture.coordinator.tableView(fixture.tableView, dragSessionDidEnd: nested)
        let loose = SupermuxFakeDragSession(dragItems: [dragItem("l1", indented: false)])
        fixture.coordinator.tableView(fixture.tableView, dragSessionWillBegin: loose)
        #expect(
            fixture.tableView.cellForRow(at: footer)?.accessibilityIdentifier
                == "MobileWorkspaceGroupFooterBoundary-group-g-active",
            "a loose row's drag no longer shows the group boundaries"
        )
    }

    // MARK: Lifting (1, 2)

    @Test func aNestedRowLiftsWhileTheLooseListCannotReorder() {
        let fixture = makeFixture(recorder: Recorder(), looseListReorders: false)
        #expect(liftedItems(fixture, row: 3).count == 1)
    }

    @Test func aNestedRowStaysPutWithoutAWayToSendItsMove() {
        let fixture = makeFixture(recorder: Recorder(), sendsNestedMoves: false, looseListReorders: true)
        #expect(liftedItems(fixture, row: 3).isEmpty)
    }

    @Test func aNestedRowStaysPutOnAMacThatCannotMoveWorkspaces() {
        let fixture = makeFixture(recorder: Recorder(), bCanMove: false)
        #expect(liftedItems(fixture, row: 3).isEmpty)
        #expect(liftedItems(fixture, row: 2).count == 1)
    }

    @Test func aRowAloneInItsProjectStaysPut() {
        let fixture = makeFixture(recorder: Recorder())
        #expect(liftedItems(fixture, row: 6).isEmpty)
    }

    @Test(arguments: [0, 1, 5])
    func aProjectOrCaptionRowNeverLifts(row: Int) {
        let fixture = makeFixture(recorder: Recorder(), looseListReorders: true)
        #expect(liftedItems(fixture, row: row).isEmpty)
    }

    // MARK: Proposals (3)

    @Test(arguments: [2, 3, 4])
    func aDropInsideItsProjectIsProposedAsAMove(row: Int) {
        let fixture = makeFixture(recorder: Recorder())
        let (proposal, _) = proposal(fixture, dragging: dragItem("b"), to: row)
        #expect(proposal.operation == .move)
        #expect(proposal.intent == .insertAtDestinationIndexPath)
    }

    @Test(arguments: [0, 1, 5, 6, 7, 8])
    func aDropOutsideItsProjectIsForbidden(row: Int) {
        let fixture = makeFixture(recorder: Recorder(), looseListReorders: true)
        let (proposal, _) = proposal(fixture, dragging: dragItem("b"), to: row)
        #expect(proposal.operation == .forbidden)
    }

    // MARK: Dropping (4, 5)

    @Test func aDropSendsTheProjectsNewOrder() throws {
        let recorder = Recorder()
        let fixture = makeFixture(recorder: recorder, looseListReorders: true)
        let dropCoordinator = drop(fixture, dragging: "c", from: 4, to: 2)
        let move = try #require(recorder.nestedMoves.first)
        #expect(recorder.nestedMoves.count == 1)
        #expect(move.workspaceID == "c")
        #expect(move.order == ["c", "a", "b"])
        #expect(move.changesOrder)
        #expect(recorder.moveRowsCalls.isEmpty, "a nested drop went down the loose list's path")
        #expect(dropCoordinator.dropToRowCalls == [IndexPath(row: 2, section: 0)])
        #expect(Array(fixture.coordinator.renderedItems[2...4]) == [
            .workspace("c", indented: true), .workspace("a", indented: true), .workspace("b", indented: true),
        ])
    }

    @Test func aDropDownTheProjectSendsItsOrder() throws {
        let recorder = Recorder()
        let fixture = makeFixture(recorder: recorder)
        _ = drop(fixture, dragging: "a", from: 2, to: 4)
        #expect(recorder.nestedMoves.map(\.order) == [["b", "c", "a"]])
    }

    @Test func aDropOnItsOwnPlaceSendsNothing() {
        let recorder = Recorder()
        let fixture = makeFixture(recorder: recorder)
        let dropCoordinator = drop(fixture, dragging: "b", from: 3, to: 3)
        #expect(recorder.nestedMoves.isEmpty)
        #expect(dropCoordinator.dropToRowCalls == [IndexPath(row: 3, section: 0)])
    }

    // MARK: Loose rows (6)

    @Test(arguments: [2, 3, 4, 6])
    func aLooseRowCannotDropIntoTheNestedRows(row: Int) {
        let fixture = makeFixture(recorder: Recorder(), looseListReorders: true)
        let (proposal, _) = proposal(fixture, dragging: dragItem("l2", indented: false), to: row)
        #expect(proposal.operation == .forbidden)
    }

    @Test func aLooseRowStillReordersThroughUpstreamsPath() throws {
        let recorder = Recorder()
        let fixture = makeFixture(recorder: recorder, looseListReorders: true)
        _ = drop(fixture, dragging: "l2", from: 8, to: 7, indented: false)
        let call = try #require(recorder.moveRowsCalls.first)
        #expect(call.0 == IndexSet(integer: 1))
        #expect(call.1 == 0)
        #expect(recorder.nestedMoves.isEmpty)
    }
}

/// The loose rows beside those nested rows, in a list scoped to one Mac.
/// Failure modes, listed before the code:
///
/// 1. No recency sort applies to one Mac's scope, yet a Recent Activity
///    choice left over from All Computers (its menu is hidden here) keeps the
///    loose rows in the Mac's window-by-window order, while the nested rows
///    and their ordered drags on the same screen follow the shared order keys.
@MainActor
@Suite struct SupermuxOneMacListOrderTests {
    private func row(_ id: String, mac: String, window: String, key: String) -> MobileWorkspacePreview {
        var row = MobileWorkspacePreview(
            id: .init(rawValue: id), macDeviceID: mac, windowID: window, name: id, terminals: [])
        row.supermuxOrderKey = key
        return row
    }

    @Test(arguments: MobileWorkspaceSortMode.allCases)
    func oneMacsLooseRowsFollowTheSharedOrderWhateverTheHiddenSort(mode: MobileWorkspaceSortMode) async {
        // Mac A's two windows hold keys that interleave: z moved to window 2
        // and kept its key, which still fit there.
        let rows = [
            row("x", mac: "mac-a", window: "w1", key: "a0"),
            row("y", mac: "mac-a", window: "w1", key: "a2"),
            row("z", mac: "mac-a", window: "w2", key: "a1"),
            row("w", mac: "mac-a", window: "w2", key: "a5"),
            row("b", mac: "mac-b", window: "w1", key: "a3"),
        ]
        let view = await listView(rows, scopedTo: "mac-a", sort: mode)
        #expect(!view.appliesRecencySort)
        #expect(view.filteredWorkspaces.map(\.id.rawValue) == ["x", "z", "y", "w"])
    }

    private func listView(
        _ rows: [MobileWorkspacePreview],
        scopedTo mac: String,
        sort: MobileWorkspaceSortMode
    ) async -> WorkspaceListView {
        let defaults = UserDefaults(suiteName: "SupermuxOneMacListOrderTests-\(UUID().uuidString)") ?? .standard
        let pairedMacs = ["mac-a", "mac-b"].map {
            MobilePairedMac(
                macDeviceID: $0, displayName: $0, routes: [], createdAt: Date(timeIntervalSince1970: 0),
                lastSeenAt: Date(timeIntervalSince1970: 10), isActive: false, stackUserID: "user-1", teamID: "team-a")
        }
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .disconnected,
            pairedMacStore: WorkspaceMacSelectionPairedMacStore(pairedMacs),
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults,
            groupCollapseStore: MobileWorkspaceGroupCollapseStore(defaults: defaults),
            workspaceSortStore: MobileWorkspaceSortStore(defaults: defaults)
        )
        await store.loadPairedMacs()
        var selection = WorkspaceMacSelection.machine(mac)
        return WorkspaceListView(
            workspaces: rows,
            groups: [],
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .unavailable,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: Binding(get: { selection }, set: { selection = $0 }),
            store: store,
            moveWorkspace: nil,
            workspaceSortMode: sort,
            setWorkspaceSortMode: { _ in },
            workspaceComputerPriority: [],
            setWorkspaceComputerPriority: { _ in },
            filterState: WorkspaceListFilterState(),
            searchText: ""
        )
    }
}

// MARK: - Protocol mocks (the drop tests' mocks are file-private there)

@MainActor
private final class SupermuxFakeDropSession: NSObject, UIDropSession {
    let dragItems: [UIDragItem]
    let locationPoint: CGPoint
    let embeddedDragSession: SupermuxFakeDragSession

    init(dragItems: [UIDragItem], location: CGPoint) {
        self.dragItems = dragItems
        self.locationPoint = location
        self.embeddedDragSession = SupermuxFakeDragSession(dragItems: dragItems, location: location)
    }

    var localDragSession: UIDragSession? { embeddedDragSession }
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .default
    nonisolated var progress: Progress { Progress() }
    var items: [UIDragItem] { dragItems }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }

    func location(in view: UIView) -> CGPoint { locationPoint }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(
        ofClass aClass: NSItemProviderReading.Type,
        completion: @escaping ([NSItemProviderReading]) -> Void
    ) -> Progress { Progress() }
}

private final class SupermuxFakeDragSession: NSObject, UIDragSession {
    let dragItems: [UIDragItem]
    let locationPoint: CGPoint

    init(dragItems: [UIDragItem] = [], location: CGPoint = .zero) {
        self.dragItems = dragItems
        self.locationPoint = location
    }

    var localContext: Any?
    var items: [UIDragItem] { dragItems }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }

    func location(in view: UIView) -> CGPoint { locationPoint }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
}

private final class SupermuxFakeDropItem: NSObject, UITableViewDropItem {
    let dragItem: UIDragItem
    let sourceIndexPath: IndexPath?
    let previewSize: CGSize = .zero

    init(dragItem: UIDragItem, sourceIndexPath: IndexPath?) {
        self.dragItem = dragItem
        self.sourceIndexPath = sourceIndexPath
    }
}

private final class SupermuxFakeDragAnimating: NSObject, UIDragAnimating {
    func addAnimations(_ animations: @escaping () -> Void) {}
    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {}
}

private final class SupermuxFakeDropCoordinator: NSObject, UITableViewDropCoordinator {
    let session: UIDropSession
    let proposal: UITableViewDropProposal
    let items: [UITableViewDropItem]
    let destinationIndexPath: IndexPath?
    private(set) var dropToRowCalls: [IndexPath] = []
    private let animator = SupermuxFakeDragAnimating()

    init(
        session: UIDropSession,
        proposal: UITableViewDropProposal,
        items: [UITableViewDropItem],
        destinationIndexPath: IndexPath?
    ) {
        self.session = session
        self.proposal = proposal
        self.items = items
        self.destinationIndexPath = destinationIndexPath
    }

    func drop(_ dragItem: UIDragItem, to placeholder: UITableViewDropPlaceholder) -> UITableViewDropPlaceholderContext {
        fatalError("unused in these tests")
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, toRowAt indexPath: IndexPath) -> UIDragAnimating {
        dropToRowCalls.append(indexPath)
        return animator
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, intoRowAt indexPath: IndexPath, rect: CGRect) -> UIDragAnimating {
        animator
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, to target: UIDragPreviewTarget) -> UIDragAnimating {
        animator
    }
}
#endif
// SUPERMUX:end supermux-mobile-nested-reorder

import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The iPhone's workspace list keeps the Mac sidebar's order, and a workspace
/// nested under a project can be dragged to a new place that its Mac applies.
/// Failure modes, listed before the code:
///
/// 1. Order: the phone puts every Mac's pinned rows first inside a merged
///    project, while each Mac's sidebar shows its own pinned rows, then its
///    other rows, Mac after Mac.
/// 2. Order: scoped to one Mac, the projects follow another Mac's project
///    order (then alphabetical), not the scoped Mac's sidebar.
/// 3. A drop lands outside its project, on another Mac's or window's rows, or
///    across the pinned line: the Mac cannot apply it (wrong Mac, unknown
///    window) or clamps it somewhere else.
/// 4. The Mac gets the wrong anchor: a drop between two rows must land right
///    before the next row of the project; a drop at the project's end right
///    after its last row, which in the Mac's tabs is before the next tab of
///    that window (a loose or another project's tab), or the window's end.
/// 5. A second drag sent while the first is still on its way computes its
///    anchor from the stale list and lands in the wrong place.
/// 6. Under the Recent Activity sort the rows have no spatial place to send.
/// 7. The dropped row jumps back until the Mac answers, stays moved after the
///    Mac refused, or an earlier move's answer undoes a later move's order.
/// 8. Moves reach the Mac out of order.
@MainActor
@Suite struct SupermuxNestedReorderTests {
    private let macBook = SupermuxMacInfo(
        macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook",
        colorIndex: 0, status: .connected, isForeground: false)
    private let studio = SupermuxMacInfo(
        macDeviceID: "mac-studio", instanceTag: "default", displayName: "Studio",
        colorIndex: 1, status: .connected, isForeground: true)

    private func group(_ mac: SupermuxMacInfo, _ projects: [String]) -> SupermuxProjectsMacGroupSnapshot {
        SupermuxProjectsMacGroupSnapshot(
            header: SupermuxProjectsMacHeader(mac: mac),
            hasLoaded: true,
            rows: projects.map { name in
                SupermuxProjectRowSnapshot(
                    project: SupermuxProjectDTO(id: "\(mac.displayName)-\(name)", name: name, rootPath: "/Users/dev/\(name)"),
                    pairingID: mac.pairingID)
            })
    }

    private func workspace(
        _ id: String,
        on mac: SupermuxMacInfo,
        project: String?,
        window: String = "w1",
        pinned: Bool = false
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: .init(rawValue: id), macDeviceID: mac.macDeviceID, windowID: window, name: id, isPinned: pinned,
            terminals: [])
        workspace.macInstanceTag = mac.instanceTag
        workspace.supermuxProjectID = project.map { "\(mac.displayName)-\($0)" }
        workspace.actionCapabilities.supportsMoveActions = true
        return workspace
    }

    private func layout(
        _ groups: [SupermuxProjectsMacGroupSnapshot],
        _ workspaces: [MobileWorkspacePreview],
        scopedTo mac: SupermuxMacInfo? = nil,
        recency: Bool = false,
        nestedOrder: [String: [MobileWorkspacePreview.ID]] = [:]
    ) -> SupermuxProjectsListLayout {
        let filter = mac.map { MobileWorkspaceListFilter(machines: [$0.pairingID]) } ?? .all
        return SupermuxProjectsListLayout(
            section: SupermuxProjectsSectionSnapshot(isCollapsed: false, groups: groups),
            workspaces: workspaces,
            scope: SupermuxProjectsListScope(query: "", filter: .all, activeFilter: filter, appliesRecencySort: recency),
            canEdit: false,
            preparingNewWorktreeProjectID: nil,
            nestedOrder: nestedOrder)
    }

    /// The rows the leading run shows, by name: `#name` for a project row.
    private func rows(_ layout: SupermuxProjectsListLayout) -> [String] {
        layout.entries.compactMap { entry in
            switch entry {
            case .workspace(let id):
                return id.rawValue
            case .fork(let id):
                guard case .project(let value)? = layout.forkRows[id] else { return nil }
                return "#\(value.display.name)"
            }
        }
    }

    // MARK: Order (1, 2)

    @Test func aMergedProjectListsEachMacsPinnedRowsFirstLikeItsSidebar() {
        let list = layout(
            [group(macBook, ["cmux"]), group(studio, ["cmux"])],
            [
                workspace("b-pinned", on: macBook, project: "cmux", pinned: true),
                workspace("b-loose", on: macBook, project: "cmux"),
                workspace("s-pinned", on: studio, project: "cmux", pinned: true),
                workspace("s-loose", on: studio, project: "cmux"),
            ])
        #expect(rows(list) == ["#cmux", "b-pinned", "b-loose", "s-pinned", "s-loose"])
    }

    @Test func aListScopedToOneMacFollowsThatMacsProjectOrder() {
        let list = layout(
            [group(macBook, ["alpha"]), group(studio, ["zeta", "alpha", "beta"])],
            [],
            scopedTo: studio)
        #expect(rows(list) == ["#zeta", "#alpha", "#beta"])
    }

    @Test func allComputersKeepsTheHomeMacsProjectOrderFirst() {
        let list = layout([group(macBook, ["zeta", "alpha"]), group(studio, ["beta", "alpha"])], [])
        #expect(rows(list) == ["#zeta", "#alpha", "#beta"])
    }

    // MARK: Segments (3, 6)

    @Test func rowsShareASegmentOnlyInOneProjectMacWindowAndPinTier() throws {
        let list = layout(
            [group(macBook, ["cmux", "infra"]), group(studio, ["cmux"])],
            [
                workspace("pinned", on: macBook, project: "cmux", pinned: true),
                workspace("a", on: macBook, project: "cmux"),
                workspace("b", on: macBook, project: "cmux"),
                workspace("other-window", on: macBook, project: "cmux", window: "w2"),
                workspace("infra", on: macBook, project: "infra"),
                workspace("studio", on: studio, project: "cmux"),
            ])
        let segments = list.nestedSegments
        let a = try #require(segments["a"])
        #expect(segments["b"] == a)
        for other in ["pinned", "other-window", "infra", "studio"] {
            let segment = try #require(segments[MobileWorkspacePreview.ID(rawValue: other)], "\(other) is not draggable")
            #expect(segment != a, "\(other) shares a's segment")
        }
    }

    @Test func theRecentActivitySortOffersNoNestedDrag() {
        let list = layout(
            [group(macBook, ["cmux"])],
            [workspace("a", on: macBook, project: "cmux"), workspace("b", on: macBook, project: "cmux")],
            recency: true)
        #expect(list.nestedSegments.isEmpty)
    }

    @Test func aMoveOnItsWayShowsItsOrderInItsSegmentOnly() throws {
        let groups = [group(macBook, ["cmux", "infra"])]
        let workspaces = [
            workspace("a", on: macBook, project: "cmux"),
            workspace("b", on: macBook, project: "cmux"),
            workspace("c", on: macBook, project: "cmux"),
            workspace("x", on: macBook, project: "infra"),
            workspace("y", on: macBook, project: "infra"),
        ]
        let segment = try #require(layout(groups, workspaces).nestedSegments["a"])
        let moved = layout(groups, workspaces, nestedOrder: [segment: ["c", "a", "b"]])
        #expect(rows(moved) == ["#cmux", "c", "a", "b", "#infra", "x", "y"])
    }

    // MARK: The drop (3)

    /// header, #cmux, a, b, c, #infra, x
    private var leadingRun: [MobileWorkspacePreview.ID?] { [nil, nil, "a", "b", "c", nil, "x"] }
    private var segments: [MobileWorkspacePreview.ID: String] { ["a": "cmux", "b": "cmux", "c": "cmux", "x": "infra"] }

    @Test func aDropInsideItsProjectIsAMove() throws {
        let move = try #require(SupermuxNestedReorderPolicy.move(leadingRun: leadingRun, from: 4, to: 2, segments: segments))
        #expect(move == SupermuxNestedMove(workspaceID: "c", segment: "cmux", order: ["c", "a", "b"], changesOrder: true))
        let down = try #require(SupermuxNestedReorderPolicy.move(leadingRun: leadingRun, from: 2, to: 4, segments: segments))
        #expect(down.order == ["b", "c", "a"])
    }

    @Test func aDropOnItsOwnPlaceChangesNothing() throws {
        let move = try #require(SupermuxNestedReorderPolicy.move(leadingRun: leadingRun, from: 3, to: 3, segments: segments))
        #expect(!move.changesOrder)
        #expect(move.order == ["a", "b", "c"])
    }

    @Test(arguments: [0, 1, 5, 6])
    func aDropOutsideItsProjectIsRefused(destination: Int) {
        #expect(SupermuxNestedReorderPolicy.move(leadingRun: leadingRun, from: 2, to: destination, segments: segments) == nil)
    }

    @Test func onlyANestedRowMoves() {
        #expect(SupermuxNestedReorderPolicy.move(leadingRun: leadingRun, from: 1, to: 3, segments: segments) == nil)
        #expect(SupermuxNestedReorderPolicy.move(leadingRun: leadingRun, from: 9, to: 3, segments: segments) == nil)
    }

    // MARK: The anchor sent to the Mac (4, 5)

    @Test func aDropBetweenRowsGoesBeforeTheNextRowOfTheProject() {
        let move = SupermuxNestedMove(workspaceID: "c", segment: "cmux", order: ["a", "c", "b"], changesOrder: true)
        #expect(SupermuxNestedReorderPolicy.beforeWorkspaceID(for: move, in: windowTabs) == "b")
    }

    /// MacBook's window w1 in its tab order, with its other window and the
    /// Studio's rows around it, as the shell lists them.
    private var windowTabs: [MobileWorkspacePreview] {
        [
            workspace("a", on: macBook, project: "cmux"),
            workspace("b", on: macBook, project: "cmux"),
            workspace("c", on: macBook, project: "cmux"),
            workspace("loose", on: macBook, project: nil),
            workspace("x", on: macBook, project: "infra"),
            workspace("w2-row", on: macBook, project: nil, window: "w2"),
            workspace("studio-row", on: studio, project: nil),
        ]
    }

    @Test func aDropAtTheProjectsEndGoesBeforeTheNextTabOfItsWindow() {
        let move = SupermuxNestedMove(workspaceID: "a", segment: "cmux", order: ["b", "c", "a"], changesOrder: true)
        #expect(SupermuxNestedReorderPolicy.beforeWorkspaceID(for: move, in: windowTabs) == "loose")
    }

    @Test func aDropAtTheEndOfItsWindowSendsNoAnchor() {
        let tabs = [
            workspace("a", on: macBook, project: "cmux"),
            workspace("b", on: macBook, project: "cmux"),
            workspace("w2-row", on: macBook, project: nil, window: "w2"),
            workspace("studio-row", on: studio, project: nil),
        ]
        let move = SupermuxNestedMove(workspaceID: "a", segment: "cmux", order: ["b", "a"], changesOrder: true)
        #expect(SupermuxNestedReorderPolicy.beforeWorkspaceID(for: move, in: tabs) == nil)
    }

    @Test func aDropAtTheEndSkipsRowsAnEarlierMoveStillOnItsWayPlacesFirst() {
        // c → front is on its way (the phone shows c, a, b; the list still
        // says a, b, c); now a goes to the end: c, b, a. The Mac, after the
        // first move, holds c, a, b, loose: a must go before `loose`, not c.
        let move = SupermuxNestedMove(workspaceID: "a", segment: "cmux", order: ["c", "b", "a"], changesOrder: true)
        #expect(SupermuxNestedReorderPolicy.beforeWorkspaceID(for: move, in: windowTabs) == "loose")
    }

    // MARK: Showing and sending (7, 8)

    private func move(_ order: [MobileWorkspacePreview.ID], segment: String = "cmux") -> SupermuxNestedMove {
        SupermuxNestedMove(workspaceID: order[0], segment: segment, order: order, changesOrder: true)
    }

    @Test func aMoveShowsAtOnceAndEndsWhenTheMacAnswered() async {
        let model = SupermuxNestedReorderModel()
        let gate = AsyncGate()
        let task = model.perform(move(["c", "a", "b"])) { await gate.wait(); return true }
        #expect(model.orders["cmux"] == ["c", "a", "b"])
        await gate.open()
        await task.value
        #expect(model.orders["cmux"] == nil)
    }

    @Test func aRefusedMoveFallsBackToTheMacsOrder() async {
        let model = SupermuxNestedReorderModel()
        await model.perform(move(["c", "a", "b"])) { false }.value
        #expect(model.orders.isEmpty)
    }

    @Test func anEarlierAnswerKeepsALaterMovesOrder() async {
        let model = SupermuxNestedReorderModel()
        let first = AsyncGate()
        let second = AsyncGate()
        let one = model.perform(move(["c", "a", "b"])) { await first.wait(); return true }
        let two = model.perform(move(["b", "c", "a"])) { await second.wait(); return true }
        await first.open()
        await one.value
        #expect(model.orders["cmux"] == ["b", "c", "a"])
        await second.open()
        await two.value
        #expect(model.orders["cmux"] == nil)
    }

    @Test func movesReachTheMacInOrder() async {
        let model = SupermuxNestedReorderModel()
        let first = AsyncGate()
        var sent: [String] = []
        let one = model.perform(move(["c", "a", "b"])) { sent.append("one"); await first.wait(); return true }
        let two = model.perform(move(["x", "y"], segment: "infra")) { sent.append("two"); return true }
        await Task.yield()
        await Task.yield()
        #expect(sent == ["one"], "the second move left before the first was answered")
        await first.open()
        await one.value
        await two.value
        #expect(sent == ["one", "two"])
    }
}

/// A one-shot gate a test opens to let a suspended send finish.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

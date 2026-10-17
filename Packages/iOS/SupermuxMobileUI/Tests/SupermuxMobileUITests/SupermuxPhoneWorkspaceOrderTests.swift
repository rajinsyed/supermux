import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The iPhone shows workspaces in the one order every Mac shares: each row's
/// owner Mac writes its order key, and the phone sorts by it, across Macs.
/// Failure modes, listed before the code (numbers from the design's §4):
///
/// 1. (#46) Only old Macs: no row has a key, and the list changes order
///    anyway (pinned rows regrouped, groups gathered) instead of staying
///    exactly as today.
/// 2. (#47) Keyed and unkeyed rows mixed: an unkeyed row jumps among keyed
///    ones, or keyed rows of one tier split around it.
/// 3. (#3) A malformed key from the wire is sorted as a key instead of
///    counting as no key.
/// 4. (#9, #4) Two Macs' rows with equal keys order differently from the
///    Mac, because the tie breaks on the phone's row id or on case.
/// 5. Tiers mix: an unpinned row sorts above a pinned one, or a row in a
///    pinned group is treated as unpinned.
/// 6. (#32, #54) A group is split by another Mac's row, leaving stray
///    members.
/// 7. (#51) Stable and Nightly builds (keys unrelated) interleave instead of
///    keeping one block per instance tag.
/// 8. The computer-priority sort loses its Mac blocks, or the Recent
///    Activity sort (#53) is re-sorted.
/// 9. Nested rows of a project stay Mac by Mac although their Macs share
///    one order; or a nested drag cannot cross Macs because keyed rows keep
///    per-Mac segments; or an unkeyed row joins the shared segment and gets
///    sent a key move its Mac cannot serve.
/// 10. (#47) Nested segments are not contiguous, so the drop policy refuses
///     moves or lands them wrong.
/// 11. (#49) After a cross-Mac move the owner's list comes back Mac by Mac:
///     waiting for the raw list to show the move never ends.
/// 12. (#48, #6) The minted key does not fall between the new neighbours,
///     traps on equal-key neighbours, or uses a closed row's missing key.
/// 13. (#58, #65) Projects: an older copy's stamp decides the project's
///     place, or projects without a stamp jump above stamped ones instead
///     of keeping the home Mac's order after them (#61).
@MainActor
@Suite struct SupermuxPhoneWorkspaceOrderTests {
    private let order = SupermuxPhoneWorkspaceOrder()
    private let macBook = SupermuxMacInfo(
        macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook",
        colorIndex: 0, status: .connected, isForeground: false)
    private let studio = SupermuxMacInfo(
        macDeviceID: "mac-studio", instanceTag: "default", displayName: "Studio",
        colorIndex: 1, status: .connected, isForeground: true)
    private let nightly = SupermuxMacInfo(
        macDeviceID: "mac-book", instanceTag: "nightly", displayName: "MacBook Nightly",
        colorIndex: 2, status: .connected, isForeground: false)

    private func workspace(
        _ id: String,
        on mac: SupermuxMacInfo,
        key: String? = nil,
        project: String? = nil,
        window: String = "w1",
        pinned: Bool = false,
        group: String? = nil
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: .init(rawValue: id), macDeviceID: mac.macDeviceID, windowID: window, name: id, isPinned: pinned,
            groupID: group.map { .init(rawValue: $0) }, terminals: [])
        workspace.macInstanceTag = mac.instanceTag
        workspace.supermuxOrderKey = key
        workspace.supermuxProjectID = project.map { "\(mac.displayName)-\($0)" }
        workspace.actionCapabilities.supportsMoveActions = true
        return workspace
    }

    private func groups(_ entries: [(id: String, pinned: Bool)]) -> [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview] {
        Dictionary(uniqueKeysWithValues: entries.map { entry in
            let id = MobileWorkspaceGroupPreview.ID(rawValue: entry.id)
            return (id, MobileWorkspaceGroupPreview(
                id: id, name: entry.id, isPinned: entry.pinned, anchorWorkspaceID: .init(rawValue: entry.id)))
        })
    }

    private func ids(_ rows: [MobileWorkspacePreview]) -> [String] { rows.map(\.id.rawValue) }

    // MARK: Loose rows (1–8)

    @Test(arguments: MobileWorkspaceSortMode.allCases)
    func withoutKeysTheListKeepsItsOrder(mode: MobileWorkspaceSortMode) {
        let rows = [
            workspace("b-loose", on: macBook),
            workspace("b-pinned", on: macBook, pinned: true),
            workspace("b-grouped", on: macBook, group: "g"),
            workspace("s-loose", on: studio),
            workspace("b-grouped-2", on: macBook, group: "g"),
        ]
        #expect(ids(order.loose(rows, groups: groups([("g", false)]), mode: mode)) == ids(rows))
    }

    @Test func automaticInterleavesMacsByKey() {
        let rows = [
            workspace("b1", on: macBook, key: "a1"),
            workspace("b3", on: macBook, key: "a3"),
            workspace("s2", on: studio, key: "a2"),
        ]
        #expect(ids(order.loose(rows, groups: [:], mode: .automatic)) == ["b1", "s2", "b3"])
    }

    @Test func unkeyedAndMalformedRowsFollowTheKeyedOnesOfTheirTier() {
        let rows = [
            workspace("old", on: studio),
            workspace("bad", on: studio, key: "!!"),
            workspace("b2", on: macBook, key: "a2"),
            workspace("b1", on: macBook, key: "a1"),
            workspace("pinned-old", on: studio, pinned: true),
            workspace("pinned", on: macBook, key: "a5", pinned: true),
        ]
        #expect(ids(order.loose(rows, groups: [:], mode: .automatic)) == ["pinned", "pinned-old", "b1", "b2", "old", "bad"])
    }

    @Test func equalKeysBreakOnTheOwnersUppercasedWorkspaceID() {
        let rows = [
            workspace("ws-2", on: macBook, key: "a1"),
            workspace("WS-1", on: studio, key: "a1"),
        ]
        #expect(ids(order.loose(rows, groups: [:], mode: .automatic)) == ["WS-1", "ws-2"])
    }

    @Test func aRowInAPinnedGroupSortsWithThePinnedRows() {
        let rows = [
            workspace("s-pinned", on: studio, key: "a5", pinned: true),
            workspace("b-loose", on: macBook, key: "a0"),
            workspace("b-in-pinned-group", on: macBook, key: "a9", group: "g"),
        ]
        #expect(ids(order.loose(rows, groups: groups([("g", true)]), mode: .automatic))
            == ["s-pinned", "b-in-pinned-group", "b-loose"])
    }

    @Test func aGroupStaysTogetherAroundAnotherMacsRow() {
        let rows = [
            workspace("g1", on: macBook, key: "a1", group: "g"),
            workspace("g4", on: macBook, key: "a4", group: "g"),
            workspace("b5", on: macBook, key: "a5"),
            workspace("s2", on: studio, key: "a2"),
        ]
        #expect(ids(order.loose(rows, groups: groups([("g", false)]), mode: .automatic)) == ["g1", "g4", "s2", "b5"])
    }

    @Test func eachInstanceTagIsItsOwnBlock() {
        let rows = [
            workspace("b5", on: macBook, key: "a5"),
            workspace("n1", on: nightly, key: "a1"),
            workspace("s2", on: studio, key: "a2"),
        ]
        #expect(ids(order.loose(rows, groups: [:], mode: .automatic)) == ["s2", "b5", "n1"])
    }

    @Test func computerPriorityKeepsEachMacsBlock() {
        let rows = [
            workspace("b2", on: macBook, key: "a2"),
            workspace("b4", on: macBook, key: "a4"),
            workspace("s1", on: studio, key: "a1"),
        ]
        #expect(ids(order.loose(rows, groups: [:], mode: .computerPriority)) == ["b2", "b4", "s1"])
        #expect(ids(order.loose(rows, groups: [:], mode: .automatic)) == ["s1", "b2", "b4"])
    }

    @Test func recentActivityIsUntouched() {
        let rows = [
            workspace("b3", on: macBook, key: "a3"),
            workspace("s1", on: studio, key: "a1"),
        ]
        #expect(ids(order.loose(rows, groups: [:], mode: .recentActivity)) == ["b3", "s1"])
    }

    // MARK: Nested rows and segments (9, 10)

    private func group(_ mac: SupermuxMacInfo, _ projects: [(name: String, order: SupermuxOrderStamp?)]) -> SupermuxProjectsMacGroupSnapshot {
        SupermuxProjectsMacGroupSnapshot(
            header: SupermuxProjectsMacHeader(mac: mac),
            hasLoaded: true,
            rows: projects.map { project in
                SupermuxProjectRowSnapshot(
                    project: SupermuxProjectDTO(
                        id: "\(mac.displayName)-\(project.name)", name: project.name,
                        rootPath: "/Users/dev/\(project.name)", order: project.order),
                    pairingID: mac.pairingID)
            })
    }

    private func group(_ mac: SupermuxMacInfo, _ projects: [String]) -> SupermuxProjectsMacGroupSnapshot {
        group(mac, projects.map { (name: $0, order: nil) })
    }

    private func layout(
        _ groups: [SupermuxProjectsMacGroupSnapshot],
        _ workspaces: [MobileWorkspacePreview]
    ) -> SupermuxProjectsListLayout {
        SupermuxProjectsListLayout(
            section: SupermuxProjectsSectionSnapshot(isCollapsed: false, groups: groups),
            workspaces: workspaces,
            scope: SupermuxProjectsListScope(query: "", filter: .all, activeFilter: .all, appliesRecencySort: false),
            canEdit: false,
            preparingNewWorktreeProjectID: nil)
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

    @Test func keyedNestedRowsFollowTheSharedOrderAcrossMacs() {
        let list = layout(
            [group(macBook, ["cmux"]), group(studio, ["cmux"])],
            [
                workspace("b1", on: macBook, key: "a1", project: "cmux"),
                workspace("b3", on: macBook, key: "a3", project: "cmux"),
                workspace("s2", on: studio, key: "a2", project: "cmux"),
            ])
        #expect(rows(list) == ["#cmux", "b1", "s2", "b3"])
    }

    @Test func keyedRowsShareOneSegmentAcrossMacsAndWindows() throws {
        let list = layout(
            [group(macBook, ["cmux"]), group(studio, ["cmux"]), group(nightly, ["cmux"])],
            [
                workspace("b1", on: macBook, key: "a1", project: "cmux"),
                workspace("b-w2", on: macBook, key: "a4", project: "cmux", window: "w2"),
                workspace("s2", on: studio, key: "a2", project: "cmux"),
                workspace("pinned", on: studio, key: "a0", project: "cmux", pinned: true),
                workspace("nightly", on: nightly, key: "a3", project: "cmux"),
                workspace("old", on: studio, project: "cmux"),
            ])
        let segments = list.nestedSegments
        let shared = try #require(segments["b1"])
        #expect(segments["b-w2"] == shared)
        #expect(segments["s2"] == shared)
        #expect(order.isOrdered(segment: shared))
        for other in ["pinned", "nightly", "old"] {
            let segment = try #require(segments[MobileWorkspacePreview.ID(rawValue: other)], "\(other) is not draggable")
            #expect(segment != shared, "\(other) shares the keyed rows' segment")
        }
        #expect(!order.isOrdered(segment: try #require(segments["old"])), "an unkeyed row was given a key move")
    }

    @Test func keyedNestedRowsComeFirstAndEverySegmentIsOneRun() {
        let list = layout(
            [group(macBook, ["cmux"]), group(studio, ["cmux"])],
            [
                workspace("b-old", on: macBook, project: "cmux"),
                workspace("b2", on: macBook, key: "a2", project: "cmux"),
                workspace("s-old", on: studio, project: "cmux"),
                workspace("s1", on: studio, key: "a1", project: "cmux"),
            ])
        #expect(rows(list) == ["#cmux", "s1", "b2", "b-old", "s-old"])
        let shown = rows(list).dropFirst().map { list.nestedSegments[MobileWorkspacePreview.ID(rawValue: $0)] }
        var finished = Set<String?>()
        var previous: String??
        for segment in shown where segment != previous {
            #expect(finished.insert(segment).inserted, "segment \(String(describing: segment)) is split")
            previous = segment
        }
    }

    @Test func withoutKeysNestedRowsStayMacByMac() {
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

    // MARK: Waiting for the list (11)

    @Test func theKeySortedListHoldsACrossMacMove() {
        // s2 dropped above b1; its owner gave it a key before a1. The shell's
        // list still comes Mac by Mac.
        let move = SupermuxNestedMove(workspaceID: "s2", segment: "ordered", order: ["s2", "b1", "b3"], changesOrder: true)
        let list = [
            workspace("b1", on: macBook, key: "a1", project: "cmux"),
            workspace("b3", on: macBook, key: "a3", project: "cmux"),
            workspace("s2", on: studio, key: "Zz", project: "cmux"),
        ]
        #expect(!SupermuxNestedReorderPolicy().listHolds(move, list))
        #expect(SupermuxNestedReorderPolicy().listHolds(move, order.nested(list)))
    }

    // MARK: The key sent to the owner (12)

    private var keyedRows: [MobileWorkspacePreview] {
        [
            workspace("b1", on: macBook, key: "a1", project: "cmux"),
            workspace("b3", on: macBook, key: "a3", project: "cmux"),
            workspace("s2", on: studio, key: "a2", project: "cmux"),
        ]
    }

    private func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    @Test func aKeyDroppedBetweenTwoRowsFallsBetweenTheirKeys() {
        let move = SupermuxNestedMove(workspaceID: "b1", segment: "ordered", order: ["s2", "b1", "b3"], changesOrder: true)
        let key = order.mintKey(for: move, in: keyedRows, seed: "phone:test")
        #expect(SupermuxOrderKey().isValid(key))
        #expect(precedes("a2", key) && precedes(key, "a3"), "\(key) is not between a2 and a3")
    }

    @Test func aKeyDroppedAtTheTopSortsBeforeTheFirstRow() {
        let move = SupermuxNestedMove(workspaceID: "b3", segment: "ordered", order: ["b3", "b1", "s2"], changesOrder: true)
        let key = order.mintKey(for: move, in: keyedRows, seed: "phone:test")
        #expect(SupermuxOrderKey().isValid(key))
        #expect(precedes(key, "a1"))
    }

    @Test func equalKeyNeighboursStillGiveAKeyRightAfterThePredecessor() {
        let rows = [
            workspace("x", on: macBook, key: "a1", project: "cmux"),
            workspace("y", on: studio, key: "a1", project: "cmux"),
            workspace("z", on: studio, key: "a2", project: "cmux"),
            workspace("moved", on: macBook, key: "a5", project: "cmux"),
        ]
        let move = SupermuxNestedMove(workspaceID: "moved", segment: "ordered", order: ["x", "moved", "y", "z"], changesOrder: true)
        let key = order.mintKey(for: move, in: rows, seed: "phone:test")
        #expect(SupermuxOrderKey().isValid(key))
        #expect(precedes("a1", key) && precedes(key, "a2"), "\(key) is not right after a1")
    }

    @Test func aClosedNeighbourIsSkipped() {
        let move = SupermuxNestedMove(
            workspaceID: "b1", segment: "ordered", order: ["s2", "closed", "b1", "b3"], changesOrder: true)
        let key = order.mintKey(for: move, in: keyedRows, seed: "phone:test")
        #expect(precedes("a2", key) && precedes(key, "a3"), "\(key) is not between a2 and a3")
    }

    // MARK: Project order (13)

    private func stamp(_ key: String, at time: Double, by origin: String = "mac:a@default") -> SupermuxOrderStamp {
        SupermuxOrderStamp(key: key, updatedAt: time, origin: origin)
    }

    @Test func theNewestStampAmongAProjectsCopiesDecidesItsPlace() {
        let list = layout(
            [
                group(macBook, [(name: "alpha", order: stamp("a0", at: 1)), (name: "beta", order: stamp("a1", at: 1))]),
                group(studio, [(name: "alpha", order: stamp("a3", at: 5))]),
            ],
            [])
        #expect(rows(list) == ["#beta", "#alpha"])
    }

    @Test func unstampedProjectsKeepTheHomeOrderAfterStampedOnes() {
        let list = layout(
            [
                group(macBook, [(name: "zeta", order: nil), (name: "alpha", order: stamp("a1", at: 1))]),
                group(studio, [(name: "beta", order: stamp("a0", at: 1))]),
            ],
            [])
        #expect(rows(list) == ["#beta", "#alpha", "#zeta"])
    }

    @Test func equalProjectKeysBreakOnTheStampNotTheProject() {
        let list = layout(
            [group(macBook, [
                (name: "alpha", order: stamp("a1", at: 2)),
                (name: "beta", order: stamp("a1", at: 1)),
            ])],
            [])
        #expect(rows(list) == ["#beta", "#alpha"])
    }
}

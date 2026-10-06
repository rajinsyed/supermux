import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// Where the iPhone shows each Mac's route: one caption line per connected
/// Mac right under the PROJECTS caption (the iPhone's merged list has no
/// per-Mac headers), and on the per-Mac headers elsewhere (W8). Failure
/// modes, listed before the code:
///
/// 1. The route never reaches the list: the section's headers drop it.
/// 2. A Mac that is reconnecting or offline still shows its last route.
/// 3. The strip shows a Mac the Mac picker filters out.
/// 4. The strip appears with no route to show (an empty row).
/// 5. The strip hides when the Projects block is folded, so the route is
///    invisible exactly when the list is shortest.
/// 6. The strip's Macs reorder when another Mac becomes the foreground.
/// 7. A Mac's line vanishes while it reconnects, and comes back after: the
///    list jumps twice and the user cannot tell the Mac is reconnecting
///    (review finding I10).
@MainActor
@Suite struct SupermuxProjectsRouteStripTests {
    private let wait = TestWait()
    private static let capabilities: Set<String> = [SupermuxMobileCapability.projectsV1.rawValue]
    private let since = Date(timeIntervalSince1970: 0)

    private let studio = SupermuxMacInfo(
        macDeviceID: "mac-studio", instanceTag: "default", displayName: "Studio",
        colorIndex: 1, status: .connected, isForeground: true)
    private let macBook = SupermuxMacInfo(
        macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook",
        colorIndex: 0, status: .connected, isForeground: false)

    private var lan: SupermuxLinkRoute { SupermuxLinkRoute(kind: .direct(.lan), rttMs: 6, since: since) }
    private var tokyo: SupermuxLinkRoute { SupermuxLinkRoute(kind: .relay(id: "apne1"), rttMs: 241, since: since) }

    private func group(_ mac: SupermuxMacInfo, route: SupermuxLinkRoute?, projectID: String) -> SupermuxProjectsMacGroupSnapshot {
        let project = SupermuxProjectDTO(id: projectID, name: projectID, rootPath: "/Users/dev/\(projectID)")
        return SupermuxProjectsMacGroupSnapshot(
            header: SupermuxProjectsMacHeader(mac: mac, route: route),
            hasLoaded: true,
            rows: [SupermuxProjectRowSnapshot(project: project, pairingID: mac.pairingID)])
    }

    private func layout(
        _ groups: [SupermuxProjectsMacGroupSnapshot],
        collapsed: Bool = false,
        filter: MobileWorkspaceListFilter = .all
    ) -> SupermuxProjectsListLayout {
        SupermuxProjectsListLayout(
            section: SupermuxProjectsSectionSnapshot(isCollapsed: collapsed, groups: groups),
            workspaces: [],
            scope: SupermuxProjectsListScope(query: "", filter: .all, activeFilter: filter, appliesRecencySort: false),
            canEdit: false,
            preparingNewWorktreeProjectID: nil)
    }

    private func strip(_ layout: SupermuxProjectsListLayout) -> [SupermuxProjectsMacHeader]? {
        guard layout.entries.count > 1, case .fork(let id) = layout.entries[1],
              case .macRoutes(let macs)? = layout.forkRows[id] else { return nil }
        return macs
    }

    @Test func aReconnectingMacShowsNoRoute() {
        let reconnecting = SupermuxMacInfo(
            macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook", status: .reconnecting)
        #expect(SupermuxProjectsMacHeader(mac: reconnecting, route: tokyo).route == nil)
        #expect(SupermuxProjectsMacHeader(mac: macBook, route: tokyo).route == tokyo)
    }

    @Test func theStripSitsUnderTheProjectsCaptionInTheStableMacOrder() {
        let macs = strip(layout([group(studio, route: lan, projectID: "a"), group(macBook, route: tokyo, projectID: "b")]))
        // MacBook holds color slot 0, so it leads whichever Mac is foreground.
        #expect(macs?.map(\.displayName) == ["MacBook", "Studio"])
        #expect(macs?.map(\.route) == [tokyo, lan])
    }

    @Test func aMacWithoutARouteIsLeftOutAndNoRouteMeansNoStrip() {
        let one = strip(layout([group(studio, route: lan, projectID: "a"), group(macBook, route: nil, projectID: "b")]))
        #expect(one?.map(\.displayName) == ["Studio"])
        #expect(strip(layout([group(studio, route: nil, projectID: "a")])) == nil)
    }

    @Test func aReconnectingMacKeepsItsLineAndShowsItsStatus() {
        let reconnecting = SupermuxMacInfo(
            macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook",
            colorIndex: 0, status: .reconnecting, isForeground: false)
        let macs = strip(layout([group(studio, route: lan, projectID: "a"), group(reconnecting, route: tokyo, projectID: "b")]))
        #expect(macs?.map(\.displayName) == ["MacBook", "Studio"], "the reconnecting Mac's line vanished")
        #expect(macs?.first?.route == nil)
        #expect(macs?.first?.status == .reconnecting)
        let alone = strip(layout([group(reconnecting, route: nil, projectID: "b")]))
        #expect(alone?.map(\.status) == [.reconnecting])
    }

    @Test func theStripStaysWhenTheBlockIsFolded() {
        let macs = strip(layout([group(studio, route: lan, projectID: "a")], collapsed: true))
        #expect(macs?.map(\.displayName) == ["Studio"])
    }

    @Test func theStripFollowsTheMacPicker() {
        let filter = MobileWorkspaceListFilter(machines: [studio.pairingID])
        let macs = strip(layout(
            [group(studio, route: lan, projectID: "a"), group(macBook, route: tokyo, projectID: "b")], filter: filter))
        #expect(macs?.map(\.displayName) == ["Studio"])
    }

    @Test func theSectionsHeadersCarryEachMacsRoute() async throws {
        let suiteName = "SupermuxProjectsRouteStripTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SupermuxProjectsSectionModel(expansionDefaults: defaults)
        model.updateMacs([studio])
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [
            SupermuxProjectDTO(id: "a", name: "Alpha", rootPath: "/Users/dev/Alpha"),
        ])
        let session = Task {
            await model.runSession(mac: studio, client: client, hostCapabilities: Self.capabilities, connectionID: "c")
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.rows.count == 1 }
        model.updateRoutes([studio.pairingID: lan])
        #expect(model.snapshot.groups.first?.header.route == lan)
        model.updateRoutes([:])
        #expect(model.snapshot.groups.first?.header.route == nil)
    }
}

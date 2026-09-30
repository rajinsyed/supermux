import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The Projects section with more than one Mac connected: every Mac that
/// serves `supermux.projects.v1` gets its own session, its projects render
/// under a per-Mac header, joins and UI state are keyed by (Mac, project),
/// and a navigation after an RPC lands on the owning Mac's row. Written as
/// the list of ways multi-Mac can go wrong.
@MainActor
@Suite struct SupermuxMultiMacSectionTests {
    private let wait = TestWait()
    private static let capabilities: Set<String> = [
        SupermuxMobileCapability.projectsV1.rawValue,
        SupermuxMobileCapability.worktreesV1.rawValue,
        SupermuxMobileCapability.presetsV1.rawValue,
        SupermuxMobileCapability.runV1.rawValue,
    ]
    private static let sharedID = "88888888-8888-8888-8888-888888888888"

    private let studio = SupermuxMacInfo(
        macDeviceID: "mac-studio", instanceTag: "default", displayName: "Studio",
        status: .connected, isForeground: true
    )
    private let macBook = SupermuxMacInfo(
        macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook",
        status: .connected, isForeground: false
    )

    private func project(_ id: String, _ name: String) -> SupermuxProjectDTO {
        SupermuxProjectDTO(id: id, name: name, rootPath: "/Users/dev/\(name)")
    }

    private func client(_ projects: [SupermuxProjectDTO]) -> FakeSupermuxMacClient {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: projects)
        return client
    }

    private func makeModel(navigationTimeout: Duration = .seconds(5)) throws -> SupermuxProjectsSectionModel {
        let suiteName = "SupermuxMultiMacSectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return SupermuxProjectsSectionModel(expansionDefaults: defaults, navigationTimeout: navigationTimeout)
    }

    private func run(
        _ model: SupermuxProjectsSectionModel,
        _ mac: SupermuxMacInfo,
        _ client: FakeSupermuxMacClient,
        connectionID: String? = nil
    ) -> Task<Void, Never> {
        Task {
            await model.runSession(
                mac: mac,
                client: client,
                hostCapabilities: Self.capabilities,
                connectionID: connectionID ?? mac.pairingID
            )
        }
    }

    /// Mutable state shared with the model's escaping closures.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func preview(id: String, mac: SupermuxMacInfo, projectID: String) -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(id: MobileWorkspacePreview.ID(rawValue: id), name: id, terminals: [])
        preview.macDeviceID = mac.macDeviceID
        preview.macInstanceTag = mac.instanceTag
        preview.supermuxProjectID = projectID
        return preview
    }

    // MARK: Grouping

    @Test func everyMacsProjectsRenderUnderItsOwnHeaderForegroundFirst() async throws {
        let model = try makeModel()
        model.updateMacs([studio, macBook])
        let sessions = [
            run(model, macBook, client([project("b-1", "Beta")])),
            run(model, studio, client([project("a-1", "Alpha")])),
        ]
        defer { sessions.forEach { $0.cancel() } }

        try await wait.until { model.snapshot.rows.count == 2 }

        let snapshot = model.snapshot
        #expect(snapshot.showsMacHeaders)
        #expect(snapshot.displayedGroups.map { $0.header.displayName } == ["Studio", "MacBook"])
        #expect(snapshot.rows.map(\.name) == ["Alpha", "Beta"])
        #expect(snapshot.rows.map(\.pairingID) == [studio.pairingID, macBook.pairingID])
        #expect(snapshot.rows.map(\.projectID) == ["a-1", "b-1"])
    }

    @Test func aSingleMacWithProjectsKeepsTheUngroupedLook() async throws {
        let model = try makeModel()
        model.updateMacs([studio, macBook])
        let sessions = [
            run(model, studio, client([project("a-1", "Alpha")])),
            run(model, macBook, client([])),
        ]
        defer { sessions.forEach { $0.cancel() } }

        try await wait.until {
            model.session(forPairingID: macBook.pairingID)?.store?.hasLoaded == true
                && model.snapshot.rows.count == 1
        }

        #expect(!model.snapshot.showsMacHeaders)
        #expect(model.snapshot.rows.map(\.name) == ["Alpha"])
    }

    @Test func theSectionStaysVisibleWhenOnlyABackgroundMacIsConnected() async throws {
        let model = try makeModel()
        model.updateMacs([studio, macBook])
        let sessions = [
            run(model, studio, client([project("a-1", "Alpha")])),
            run(model, macBook, client([project("b-1", "Beta")])),
        ]
        defer { sessions.forEach { $0.cancel() } }
        try await wait.until { model.snapshot.rows.count == 2 }

        // The foreground Mac goes offline; the MacBook's link is healthy.
        model.updateMacs([macBook])

        #expect(model.snapshot.isVisible)
        #expect(model.snapshot.rows.map(\.name) == ["Beta"])
        #expect(model.session(forPairingID: studio.pairingID) == nil)
    }

    @Test func aForegroundSwitchKeepsEveryMacsLoadedSession() async throws {
        let model = try makeModel()
        let studioClient = client([project("a-1", "Alpha")])
        let bookClient = client([project("b-1", "Beta")])
        model.updateMacs([studio, macBook])
        var sessions = [run(model, studio, studioClient), run(model, macBook, bookClient)]
        try await wait.until { model.snapshot.rows.count == 2 }
        let studioStore = try #require(model.session(forPairingID: studio.pairingID)?.store)
        let bookStore = try #require(model.session(forPairingID: macBook.pairingID)?.store)

        // Opening a MacBook workspace promotes it to foreground: the driver's
        // task restarts with the same clients and flipped roles.
        sessions.forEach { $0.cancel() }
        let promotedBook = SupermuxMacInfo(
            macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook",
            status: .connected, isForeground: true
        )
        let demotedStudio = SupermuxMacInfo(
            macDeviceID: "mac-studio", instanceTag: "default", displayName: "Studio",
            status: .connected, isForeground: false
        )
        model.updateMacs([promotedBook, demotedStudio])
        sessions = [run(model, demotedStudio, studioClient), run(model, promotedBook, bookClient)]
        defer { sessions.forEach { $0.cancel() } }

        #expect(model.session(forPairingID: studio.pairingID)?.store === studioStore)
        #expect(model.session(forPairingID: macBook.pairingID)?.store === bookStore)
        #expect(model.snapshot.rows.map(\.name) == ["Beta", "Alpha"])
    }

    // MARK: Keys and joins

    @Test func workspacesNestOnlyUnderTheirOwnMacsProject() async throws {
        let model = try makeModel()
        model.updateMacs([studio, macBook])
        let sessions = [
            run(model, studio, client([project(Self.sharedID, "Alpha")])),
            run(model, macBook, client([project(Self.sharedID, "Alpha copy")])),
        ]
        defer { sessions.forEach { $0.cancel() } }
        try await wait.until { model.snapshot.rows.count == 2 }

        model.updateWorkspaces(
            SupermuxProjectWorkspaceRowSnapshot.rows(from: [
                preview(id: "on-studio", mac: studio, projectID: Self.sharedID),
                preview(id: "on-book", mac: macBook, projectID: Self.sharedID),
            ]),
            selectWorkspace: { _ in }
        )

        let rows = model.snapshot.rows
        #expect(rows[0].openWorkspaces.map(\.id) == ["on-studio"])
        #expect(rows[1].openWorkspaces.map(\.id) == ["on-book"])
        #expect(rows[0].id != rows[1].id)
    }

    @Test func expandingAProjectExpandsItOnlyOnItsOwnMac() async throws {
        let model = try makeModel()
        model.updateMacs([studio, macBook])
        let sessions = [
            run(model, studio, client([project(Self.sharedID, "Alpha")])),
            run(model, macBook, client([project(Self.sharedID, "Alpha copy")])),
        ]
        defer { sessions.forEach { $0.cancel() } }
        try await wait.until { model.snapshot.rows.count == 2 }

        model.toggleProjectExpanded(model.snapshot.rows[1].id)

        #expect(model.snapshot.rows.map(\.isExpanded) == [false, true])
    }

    @Test func aProjectDetailRunsItsRPCsOverItsOwnMac() async throws {
        let model = try makeModel()
        let studioClient = client([project("a-1", "Alpha")])
        let bookClient = client([project("b-1", "Beta")])
        bookClient.presetLaunchResponse = SupermuxPresetLaunchResponse(workspaceId: "ws-preset")
        model.updateMacs([studio, macBook])
        let sessions = [run(model, studio, studioClient), run(model, macBook, bookClient)]
        defer { sessions.forEach { $0.cancel() } }
        try await wait.until { model.snapshot.rows.count == 2 }

        model.openProjectDetail(model.snapshot.rows[1].id)
        let context = try #require(model.detailContext)
        let runActions = try #require(context.runActions)
        _ = try await runActions.launchPreset("preset-1", context.row.projectID)

        #expect(bookClient.callLog.contains("presetLaunch"))
        #expect(!studioClient.callLog.contains("presetLaunch"))
    }

    // MARK: Navigation after an RPC

    @Test func openingABackgroundMacsProjectNavigatesToItsScopedRow() async throws {
        let model = try makeModel()
        let bookClient = client([project("b-1", "Beta")])
        bookClient.projectOpenResponse = SupermuxProjectOpenResponse(workspaceId: "ws-root")
        model.updateMacs([studio, macBook])
        let sessions = [run(model, studio, client([project("a-1", "Alpha")])), run(model, macBook, bookClient)]
        defer { sessions.forEach { $0.cancel() } }
        try await wait.until { model.snapshot.rows.count == 2 }
        let asked = Box<[SupermuxWorkspaceNavigator.Target]>([])
        let navigated = Box<[String]>([])
        model.updateWorkspaces([], selectWorkspace: { navigated.value.append($0) }, resolveWorkspace: { remote, device, tag in
            asked.value.append(.init(remoteWorkspaceID: remote, macDeviceID: device, instanceTag: tag))
            return device == "mac-book" ? "book-row-\(remote)" : nil
        })

        model.actions.openProjectWorkspace(model.snapshot.rows[1].id)
        try await wait.until { !navigated.value.isEmpty }

        #expect(asked.value.first == .init(remoteWorkspaceID: "ws-root", macDeviceID: "mac-book", instanceTag: "default"))
        #expect(navigated.value == ["book-row-ws-root"])
    }

    @Test func navigationWaitsForTheNewWorkspaceRowToArrive() async throws {
        let model = try makeModel()
        let bookClient = client([project("b-1", "Beta")])
        bookClient.projectOpenResponse = SupermuxProjectOpenResponse(workspaceId: "ws-new")
        model.updateMacs([macBook])
        let session = run(model, macBook, bookClient)
        defer { session.cancel() }
        try await wait.until { model.snapshot.rows.count == 1 }
        let listed = Box(false)
        let navigated = Box<[String]>([])
        model.updateWorkspaces([], selectWorkspace: { navigated.value.append($0) }, resolveWorkspace: { remote, _, _ in
            listed.value ? "row-\(remote)" : nil
        })

        model.actions.openProjectWorkspace(model.snapshot.rows[0].id)
        try await wait.until { bookClient.callLog.contains("projectOpen") }
        try await Task.sleep(for: .milliseconds(20))
        #expect(navigated.value.isEmpty)

        listed.value = true
        model.workspaceListDidChange()

        #expect(navigated.value == ["row-ws-new"])
        #expect(model.nestedOpenErrorMessage == nil)
    }

    @Test func aWorkspaceThatNeverArrivesSurfacesAVisibleError() async throws {
        let model = try makeModel(navigationTimeout: .milliseconds(40))
        let bookClient = client([project("b-1", "Beta")])
        bookClient.projectOpenResponse = SupermuxProjectOpenResponse(workspaceId: "ws-lost")
        model.updateMacs([macBook])
        let session = run(model, macBook, bookClient)
        defer { session.cancel() }
        try await wait.until { model.snapshot.rows.count == 1 }
        let navigated = Box<[String]>([])
        model.updateWorkspaces([], selectWorkspace: { navigated.value.append($0) }, resolveWorkspace: { _, _, _ in nil })

        model.actions.openProjectWorkspace(model.snapshot.rows[0].id)
        try await wait.until { model.nestedOpenErrorMessage != nil }

        #expect(navigated.value.isEmpty)
    }
}

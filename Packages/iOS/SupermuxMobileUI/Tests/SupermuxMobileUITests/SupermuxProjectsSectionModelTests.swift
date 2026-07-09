import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// Section view-model behavior: capability gating (UI-02), snapshot
/// projection, collapse handling, session replacement on reconnect, and the
/// icon action bundle — all against the fake Mac client.
@MainActor
@Suite struct SupermuxProjectsSectionModelTests {
    private let wait = TestWait()

    private static let projectsCapability = SupermuxMobileCapability.projectsV1.rawValue

    private func fixtureProject(
        id: String = "11111111-1111-1111-1111-111111111111",
        name: String = "Alpha",
        colorHex: String? = "#3b82f6",
        iconSymbol: String? = "folder",
        hasCustomIcon: Bool? = false
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: id,
            name: name,
            rootPath: "/Users/dev/alpha",
            colorHex: colorHex,
            iconSymbol: iconSymbol,
            hasCustomIcon: hasCustomIcon
        )
    }

    // MARK: UI-02 — capability gate

    @Test func withoutProjectsCapabilityTheSectionReportsHiddenAndIssuesNoRPC() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()

        // Upstream-cmux capability set: no supermux.* entries.
        await model.runSession(
            client: client,
            hostCapabilities: ["workspace.groups.v1", "workspace.actions.v1"]
        )

        #expect(model.snapshot.isVisible == false)
        #expect(model.snapshot.rows.isEmpty)
        #expect(client.callLog.isEmpty)
    }

    @Test func withProjectsCapabilityTheSectionReportsVisible() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()

        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.isVisible && model.snapshot.hasLoaded }
        #expect(model.snapshot.rows.map(\.name) == ["Alpha"])
    }

    // MARK: Snapshot projection

    @Test func snapshotReflectsFetchedProjectsAndEventDrivenRefetch() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject()],
            sectionCollapsed: false
        )
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.rows.count == 1 }

        client.listResponse = SupermuxProjectsListResponse(
            projects: [
                fixtureProject(),
                fixtureProject(
                    id: "22222222-2222-2222-2222-222222222222",
                    name: "Beta",
                    colorHex: nil,
                    iconSymbol: nil
                ),
            ],
            sectionCollapsed: false
        )
        client.emit(SupermuxMobileEvent(topic: .projectsUpdated))

        try await wait.until { model.snapshot.rows.count == 2 }
        #expect(model.snapshot.rows.map(\.name) == ["Alpha", "Beta"])
        #expect(client.projectsListCallCount == 2)
    }

    @Test func sessionEndHidesTheSection() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        try await wait.until { model.snapshot.isVisible }

        session.cancel()
        client.finishEventStreams()
        try await wait.until { model.snapshot.isVisible == false }

        model.endSession()
        #expect(model.snapshot == .hidden)
    }

    @Test func reconnectReplacesTheStoreWithTheNewSessionsClient() async throws {
        let firstClient = FakeSupermuxMacClient()
        firstClient.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let firstSession = Task {
            await model.runSession(client: firstClient, hostCapabilities: [Self.projectsCapability])
        }
        try await wait.until { model.snapshot.rows.map(\.name) == ["Alpha"] }

        firstSession.cancel()
        firstClient.finishEventStreams()

        let secondClient = FakeSupermuxMacClient()
        secondClient.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject(id: "33333333-3333-3333-3333-333333333333", name: "Gamma")]
        )
        let secondSession = Task {
            await model.runSession(client: secondClient, hostCapabilities: [Self.projectsCapability])
        }
        defer { secondSession.cancel() }

        try await wait.until { model.snapshot.rows.map(\.name) == ["Gamma"] }
        #expect(secondClient.projectsListCallCount == 1)
    }

    // MARK: Presets area (m2-f5)

    @Test func snapshotCarriesGlobalPresetsWhenTheHostAdvertisesPresets() async throws {
        let presets = [
            SupermuxTerminalPresetDTO(
                id: "44444444-4444-4444-4444-444444444444",
                name: "claude",
                command: "claude",
                iconSymbol: "sparkle",
                colorHex: "#f97316"
            ),
        ]
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject()],
            presets: presets
        )
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [
                    Self.projectsCapability,
                    SupermuxMobileCapability.presetsV1.rawValue,
                ]
            )
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.hasLoaded }
        #expect(model.snapshot.showsPresets)
        #expect(model.snapshot.presets == presets)
    }

    @Test func snapshotHidesThePresetsAreaWithoutThePresetsCapability() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject()],
            presets: [
                SupermuxTerminalPresetDTO(
                    id: "44444444-4444-4444-4444-444444444444",
                    name: "claude",
                    command: "claude"
                ),
            ]
        )
        let model = SupermuxProjectsSectionModel()
        // projects.v1 only — an older fork Mac must render no presets UI even
        // if the payload were to carry them.
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.hasLoaded }
        #expect(model.snapshot.showsPresets == false)
        #expect(model.snapshot.presets.isEmpty)
    }

    // MARK: Collapse

    @Test func collapseSeedsFromTheMacAndTogglesLocally() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject()],
            sectionCollapsed: true
        )
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.hasLoaded }
        #expect(model.snapshot.isCollapsed == true)

        model.actions.toggleCollapsed()
        #expect(model.snapshot.isCollapsed == false)

        model.actions.toggleCollapsed()
        #expect(model.snapshot.isCollapsed == true)
    }

    // MARK: Worktrees factory + count badge

    @Test func worktreesStoreFactoryIsNilWithoutTheWorktreesCapability() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        #expect(model.actions.makeWorktreesStore(fixtureProject().id) == nil)
    }

    @Test func worktreesStoreFactoryIsNilWithoutALiveSession() {
        let model = SupermuxProjectsSectionModel()
        #expect(model.actions.makeWorktreesStore(fixtureProject().id) == nil)
    }

    @Test func worktreesStoreFeedsTheProjectRowsWorktreeCount() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/one", branch: "one"),
            SupermuxWorktreeDTO(path: "/w/two", branch: "two"),
        ])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [
                    Self.projectsCapability,
                    SupermuxMobileCapability.worktreesV1.rawValue,
                ]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }
        // Reserved until real data exists: no badge before a fetch.
        #expect(model.snapshot.rows.first?.worktreeCount == nil)

        let store = try #require(model.actions.makeWorktreesStore(project.id))
        #expect(store.projectID == project.id)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await wait.until { model.snapshot.rows.first?.worktreeCount == 2 }
    }

    // MARK: Icon action

    @Test func iconActionFetchesBytesForAKnownProjectAndNilForUnknown() async throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let client = FakeSupermuxMacClient()
        let project = fixtureProject(hasCustomIcon: true)
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.iconResponses = [
            SupermuxProjectIconResponse(
                notModified: false,
                etag: "e1",
                pngBase64: pngBytes.base64EncodedString()
            ),
        ]
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        let fetched = await model.actions.iconPNGData(project.id)
        #expect(fetched == pngBytes)
        #expect(client.iconRequests.count == 1)

        let unknown = await model.actions.iconPNGData("not-a-project")
        #expect(unknown == nil)
        #expect(client.iconRequests.count == 1)
    }
}

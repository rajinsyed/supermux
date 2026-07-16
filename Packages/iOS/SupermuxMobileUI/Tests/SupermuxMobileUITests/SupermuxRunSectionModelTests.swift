import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The Projects section's run projection (RPC-RUN-01's phone surface):
/// capability gating for the run/presets/actions affordances, the row-level
/// running dot reflecting `run.state`, its refresh on `supermux.run.updated`,
/// and the action bundle's exact wire params — all against the fake client.
@MainActor
@Suite struct SupermuxRunSectionModelTests {
    private let wait = TestWait()

    private static let projectID = "11111111-1111-1111-1111-111111111111"
    private static let projectsCapability = SupermuxMobileCapability.projectsV1.rawValue
    private static let runCapability = SupermuxMobileCapability.runV1.rawValue
    private static let actionsCapability = SupermuxMobileCapability.actionsV1.rawValue

    private func fixtureProject(runCommands: [String]? = ["npm run dev"]) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: Self.projectID,
            name: "Alpha",
            rootPath: "/Users/dev/alpha",
            runCommands: runCommands,
            actions: [
                SupermuxProjectActionDTO(
                    id: "44444444-4444-4444-4444-444444444444",
                    name: "Dashboard",
                    command: "https://example.com/dashboard"
                ),
            ]
        )
    }

    private func runningRow(command: String = "npm run dev") -> SupermuxRunStateDTO {
        SupermuxRunStateDTO(
            projectId: Self.projectID,
            isRunning: true,
            command: command,
            workspaceId: "33333333-3333-3333-3333-333333333333"
        )
    }

    // MARK: Capability gates

    @Test func withoutRunCapabilityRowsCarryNoRunStateAndNoRunRPCIsIssued() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.hasLoaded }
        let row = try #require(model.snapshot.rows.first)
        #expect(row.run == nil)
        #expect(model.snapshot.showsActions == false)
        #expect(!client.callLog.contains("runState"))
    }

    @Test func withoutActionsCapabilityTheSnapshotHidesActions() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.runCapability]
            )
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.hasLoaded }
        #expect(model.snapshot.showsActions == false)
    }

    @Test func withActionsCapabilityTheSnapshotShowsActionsAndRowsCarryTheActionList() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.actionsCapability]
            )
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.hasLoaded }
        #expect(model.snapshot.showsActions)
        let row = try #require(model.snapshot.rows.first)
        #expect(row.actions.map(\.name) == ["Dashboard"])
    }

    @Test func projectWithoutRunCommandsCarriesNoRunStateEvenWithTheCapability() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject(runCommands: ["   "])]
        )
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.runCapability]
            )
        }
        defer { session.cancel() }

        try await wait.until { model.snapshot.hasLoaded }
        let row = try #require(model.snapshot.rows.first)
        #expect(row.run == nil)
    }

    // MARK: Running dot ⟵ run.state + supermux.run.updated (RPC-RUN-01)

    @Test func rowRunStateReflectsRunStateAndUpdatesOnRunUpdatedPoke() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        client.runStateResponse = SupermuxRunStateResponse(
            runs: [SupermuxRunStateDTO(projectId: Self.projectID, isRunning: false)]
        )
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.runCapability]
            )
        }
        defer { session.cancel() }

        try await wait.until {
            model.snapshot.hasLoaded && model.snapshot.rows.first?.run != nil
        }
        var row = try #require(model.snapshot.rows.first)
        #expect(row.run == SupermuxProjectRunState(isRunning: false, command: nil))
        #expect(row.runCommands == ["npm run dev"])

        // A desktop-side start pokes the phone; the row's dot flips.
        client.runStateResponse = SupermuxRunStateResponse(runs: [runningRow()])
        client.emit(SupermuxMobileEvent(topic: .runUpdated))

        try await wait.until { model.snapshot.rows.first?.run?.isRunning == true }
        row = try #require(model.snapshot.rows.first)
        #expect(row.run == SupermuxProjectRunState(isRunning: true, command: "npm run dev"))
        #expect(client.runStateCallCount == 2)
    }

    // MARK: Action bundle wire exactness

    @Test func bundleStartRunSendsTheExactWireParamsAndFlipsTheRow() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        client.runStartResponse = SupermuxRunWriteResponse(run: runningRow())
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.runCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }
        let run = try #require(model.actions.run)

        try await run.startRun(Self.projectID, nil)

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.run.start")
        #expect(call.params == ["project_id": Self.projectID] as NSDictionary)
        #expect(model.snapshot.rows.first?.run?.isRunning == true)
    }

    @Test func bundleStartRunWithAChosenCommandSendsTheZeroBasedIndex() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.runCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }
        let run = try #require(model.actions.run)

        try await run.startRun(Self.projectID, 1)

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.params == [
            "project_id": Self.projectID,
            "command_id": 1,
        ] as NSDictionary)
    }

    @Test func bundleStopRunSendsTheProjectID() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.runCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }
        let run = try #require(model.actions.run)

        try await run.stopRun(Self.projectID)

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.run.stop")
        #expect(call.params == ["project_id": Self.projectID] as NSDictionary)
    }

    @Test func bundleLaunchPresetTargetsTheProjectAndReturnsTheWorkspace() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        client.presetLaunchResponse = SupermuxPresetLaunchResponse(
            workspaceId: "55555555-5555-5555-5555-555555555555",
            terminalId: "66666666-6666-6666-6666-666666666666"
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
        let run = try #require(model.actions.run)

        let response = try await run.launchPreset(
            "22222222-2222-2222-2222-222222222222",
            Self.projectID
        )

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.preset.launch")
        #expect(call.params == [
            "preset_id": "22222222-2222-2222-2222-222222222222",
            "project_id": Self.projectID,
        ] as NSDictionary)
        #expect(response.workspaceId == "55555555-5555-5555-5555-555555555555")
    }

    @Test func bundleRunActionReturnsTheOpenURLOutcomeForLocalOpening() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        client.actionRunResponse = SupermuxActionRunResponse(
            kind: "open_url",
            url: "https://example.com/dashboard"
        )
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.actionsCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }
        let run = try #require(model.actions.run)

        let outcome = try await run.runAction(
            Self.projectID,
            "44444444-4444-4444-4444-444444444444"
        )

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.action.run")
        #expect(call.params == [
            "project_id": Self.projectID,
            "action_id": "44444444-4444-4444-4444-444444444444",
        ] as NSDictionary)
        #expect(outcome.opensURLLocally)
        #expect(outcome.url == "https://example.com/dashboard")
    }

    // MARK: Session lifecycle

    @Test func endSessionDropsTheRunBundleAndStore() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.runCapability]
            )
        }
        try await wait.until { model.snapshot.hasLoaded }
        #expect(model.actions.run != nil)

        session.cancel()
        client.finishEventStreams()
        model.endSession()

        #expect(model.runStore == nil)
        #expect(model.actions.run == nil)
    }
}

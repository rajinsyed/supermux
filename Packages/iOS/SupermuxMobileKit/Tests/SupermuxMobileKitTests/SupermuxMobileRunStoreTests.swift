import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// Run-store behavior (the phone's share of RPC-RUN-01): capability gating,
/// the `run.state` fetch + `supermux.run.updated` refetch loop, and the
/// start/stop/launch/action calls with their EXACT wire params — all against
/// the fake Mac client.
@MainActor
@Suite struct SupermuxMobileRunStoreTests {
    private let wait = TestWait()

    private static let projectID = "11111111-1111-1111-1111-111111111111"
    private static let runCapability = SupermuxMobileCapability.runV1.rawValue
    private static let presetsCapability = SupermuxMobileCapability.presetsV1.rawValue
    private static let actionsCapability = SupermuxMobileCapability.actionsV1.rawValue

    private func makeStore(
        client: FakeSupermuxMacClient,
        capabilities: [String] = [runCapability, presetsCapability, actionsCapability]
    ) -> SupermuxMobileRunStore {
        SupermuxMobileRunStore(
            client: client,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: capabilities)
        )
    }

    private func runningRow(command: String = "npm run dev") -> SupermuxRunStateDTO {
        SupermuxRunStateDTO(
            projectId: Self.projectID,
            isRunning: true,
            command: command,
            workspaceId: "33333333-3333-3333-3333-333333333333",
            startedAt: 1_770_000_000
        )
    }

    private func idleRow() -> SupermuxRunStateDTO {
        SupermuxRunStateDTO(projectId: Self.projectID, isRunning: false)
    }

    // MARK: Capability gate

    @Test func runLoopIsInertWithoutRunCapability() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: [])

        await store.run()

        #expect(client.callLog.isEmpty)
        #expect(store.hasLoaded == false)
    }

    @Test func startWithoutRunCapabilityThrowsUnavailable() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: [])

        await #expect(throws: SupermuxMacUnavailableError.self) {
            try await store.startRun(projectID: Self.projectID)
        }
        await #expect(throws: SupermuxMacUnavailableError.self) {
            try await store.stopRun(projectID: Self.projectID)
        }
        #expect(client.callLog.isEmpty)
    }

    @Test func launchPresetWithoutPresetsCapabilityThrowsUnavailable() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: [Self.runCapability])

        await #expect(throws: SupermuxMacUnavailableError.self) {
            _ = try await store.launchPreset(
                presetID: "22222222-2222-2222-2222-222222222222",
                projectID: Self.projectID
            )
        }
        #expect(client.callLog.isEmpty)
    }

    @Test func runActionWithoutActionsCapabilityThrowsUnavailable() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: [Self.runCapability])

        await #expect(throws: SupermuxMacUnavailableError.self) {
            _ = try await store.runAction(
                projectID: Self.projectID,
                actionID: "44444444-4444-4444-4444-444444444444"
            )
        }
        #expect(client.callLog.isEmpty)
    }

    // MARK: run.state fetch + supermux.run.updated refetch (RPC-RUN-01 phone share)

    @Test func runLoopFetchesStateAndRefetchesOnRunUpdatedPoke() async throws {
        let client = FakeSupermuxMacClient()
        client.runStateResponse = SupermuxRunStateResponse(runs: [idleRow()])
        let store = makeStore(client: client)
        let session = Task { await store.run() }
        defer { session.cancel() }

        try await wait.until { store.hasLoaded }
        #expect(store.isRunning(projectID: Self.projectID) == false)
        #expect(client.subscribedTopicSets.contains([.runUpdated]))

        // A desktop-side start pokes the phone; the store refetches and the
        // running dot's source of truth flips.
        client.runStateResponse = SupermuxRunStateResponse(runs: [runningRow()])
        client.emit(SupermuxMobileEvent(topic: .runUpdated))

        try await wait.until { store.isRunning(projectID: Self.projectID) }
        #expect(store.run(forProjectID: Self.projectID)?.command == "npm run dev")
        #expect(client.runStateCallCount == 2)
    }

    @Test func runStateWireCallCarriesTheExactMethodAndEmptyParams() async throws {
        let client = FakeSupermuxMacClient()
        client.runStateResponse = SupermuxRunStateResponse(runs: [])
        let store = makeStore(client: client)
        let session = Task { await store.run() }
        defer { session.cancel() }

        try await wait.until { store.hasLoaded }
        let call = try #require(client.recordedWireCalls.first)
        #expect(call.method == "mobile.supermux.run.state")
        #expect(call.params == [:] as NSDictionary)
    }

    // MARK: start/stop wire exactness

    @Test func startWithoutChosenCommandOmitsCommandID() async throws {
        let client = FakeSupermuxMacClient()
        client.runStartResponse = SupermuxRunWriteResponse(run: runningRow())
        let store = makeStore(client: client)

        try await store.startRun(projectID: Self.projectID)

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.run.start")
        #expect(call.params == ["project_id": Self.projectID] as NSDictionary)
    }

    @Test func startWithChosenCommandSendsTheZeroBasedIndex() async throws {
        let client = FakeSupermuxMacClient()
        client.runStartResponse = SupermuxRunWriteResponse(run: runningRow())
        let store = makeStore(client: client)

        try await store.startRun(projectID: Self.projectID, commandID: 2)

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.run.start")
        #expect(call.params == [
            "project_id": Self.projectID,
            "command_id": 2,
        ] as NSDictionary)
    }

    @Test func startAppliesTheReturnedRunStateOptimistically() async throws {
        let client = FakeSupermuxMacClient()
        client.runStartResponse = SupermuxRunWriteResponse(run: runningRow())
        let store = makeStore(client: client)

        try await store.startRun(projectID: Self.projectID)

        #expect(store.isRunning(projectID: Self.projectID))
        #expect(store.run(forProjectID: Self.projectID)?.command == "npm run dev")
    }

    @Test func stopSendsTheProjectIDAndAppliesTheReturnedState() async throws {
        let client = FakeSupermuxMacClient()
        client.runStartResponse = SupermuxRunWriteResponse(run: runningRow())
        client.runStopResponse = SupermuxRunWriteResponse(run: idleRow())
        let store = makeStore(client: client)
        try await store.startRun(projectID: Self.projectID)

        try await store.stopRun(projectID: Self.projectID)

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.run.stop")
        #expect(call.params == ["project_id": Self.projectID] as NSDictionary)
        #expect(store.isRunning(projectID: Self.projectID) == false)
    }

    @Test func startFailureRethrowsForTheControlToDisplay() async throws {
        struct WireFailure: Error {}
        let client = FakeSupermuxMacClient()
        client.runStartError = WireFailure()
        let store = makeStore(client: client)

        await #expect(throws: WireFailure.self) {
            try await store.startRun(projectID: Self.projectID)
        }
        #expect(store.isRunning(projectID: Self.projectID) == false)
    }

    // MARK: preset.launch / action.run wire exactness

    @Test func launchPresetSendsPresetAndProjectIDsAndReturnsTheTargetIDs() async throws {
        let client = FakeSupermuxMacClient()
        client.presetLaunchResponse = SupermuxPresetLaunchResponse(
            workspaceId: "55555555-5555-5555-5555-555555555555",
            terminalId: "66666666-6666-6666-6666-666666666666"
        )
        let store = makeStore(client: client)

        let response = try await store.launchPreset(
            presetID: "22222222-2222-2222-2222-222222222222",
            projectID: Self.projectID
        )

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.preset.launch")
        #expect(call.params == [
            "preset_id": "22222222-2222-2222-2222-222222222222",
            "project_id": Self.projectID,
        ] as NSDictionary)
        #expect(response.workspaceId == "55555555-5555-5555-5555-555555555555")
        #expect(response.terminalId == "66666666-6666-6666-6666-666666666666")
    }

    @Test func runActionSendsProjectAndActionIDsAndReturnsTheOutcome() async throws {
        let client = FakeSupermuxMacClient()
        client.actionRunResponse = SupermuxActionRunResponse(
            kind: "open_url",
            url: "https://example.com/dashboard"
        )
        let store = makeStore(client: client)

        let response = try await store.runAction(
            projectID: Self.projectID,
            actionID: "44444444-4444-4444-4444-444444444444"
        )

        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.action.run")
        #expect(call.params == [
            "project_id": Self.projectID,
            "action_id": "44444444-4444-4444-4444-444444444444",
        ] as NSDictionary)
        #expect(response.opensURLLocally)
        #expect(response.url == "https://example.com/dashboard")
    }

    @Test func commandActionOutcomeDoesNotOpenLocally() async throws {
        let client = FakeSupermuxMacClient()
        client.actionRunResponse = SupermuxActionRunResponse(ok: true, kind: "command")
        let store = makeStore(client: client)

        let response = try await store.runAction(
            projectID: Self.projectID,
            actionID: "44444444-4444-4444-4444-444444444444"
        )

        #expect(response.opensURLLocally == false)
        #expect(response.ok == true)
    }
}

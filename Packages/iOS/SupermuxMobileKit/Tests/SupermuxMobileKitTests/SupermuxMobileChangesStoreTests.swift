import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-04 for changes: store state transitions correctly on
/// stage/unstage/discard actions (exact §2 wire calls asserted against the
/// fake's recording), a `supermux.changes.updated` poke for THIS workspace
/// refetches the status, and the watch heartbeat fires `changes.watch
/// {enable:true}` at the expected 60 s cadence through the injected clock
/// seam — with `{enable:false}` on the way out.
@MainActor
@Suite struct SupermuxMobileChangesStoreTests {
    private static let workspaceID = "7B1D4C22-9F3A-4E0D-B7A1-5C6E8F0A2D33"

    private static let statusA = SupermuxChangesStatusDTO(
        workspaceId: workspaceID,
        isRepository: true,
        branch: "main",
        upstreamBranch: "origin/main",
        ahead: 1,
        behind: 2,
        staged: [SupermuxChangedFileDTO(path: "staged.txt", kind: "added")],
        unstaged: [SupermuxChangedFileDTO(path: "src/app.swift", kind: "modified")],
        untracked: [SupermuxChangedFileDTO(path: "notes.md", kind: "untracked")],
        stashCount: 1
    )

    private static let statusB = SupermuxChangesStatusDTO(
        workspaceId: workspaceID,
        isRepository: true,
        branch: "main",
        staged: [
            SupermuxChangedFileDTO(path: "staged.txt", kind: "added"),
            SupermuxChangedFileDTO(path: "src/app.swift", kind: "modified"),
        ],
        unstaged: [],
        untracked: [SupermuxChangedFileDTO(path: "notes.md", kind: "untracked")]
    )

    private static let changesOnly = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.changesV1.rawValue]
    )

    private func makeStore(
        fake: FakeSupermuxMacClient,
        capabilities: SupermuxMobileCapabilities = changesOnly,
        heartbeatSleep: ((Duration) async -> Void)? = nil
    ) -> SupermuxMobileChangesStore {
        SupermuxMobileChangesStore(
            client: fake,
            capabilities: capabilities,
            workspaceID: Self.workspaceID,
            idleSleep: { _ in await Task.yield() },
            heartbeatSleep: heartbeatSleep ?? { _ in
                // Park forever (until cancelled) so heartbeat-agnostic tests
                // observe exactly one initial watch call.
                try? await Task.sleep(for: .seconds(3600))
            }
        )
    }

    /// The fake's recorded `changes.watch` params, in call order.
    private func watchCalls(_ fake: FakeSupermuxMacClient) -> [NSDictionary] {
        fake.recordedWireCalls
            .filter { $0.method == "mobile.supermux.changes.watch" }
            .map(\.params)
    }

    // MARK: Status sync + event-driven refetch

    @Test func syncsStatusThenRefetchesOnMatchingChangesUpdated() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        #expect(store.status == Self.statusA)
        // Subscribe-before-fetch, on exactly the changes topic.
        #expect(fake.subscribedTopicSets.first == [.changesUpdated])
        let eventsIndex = try #require(fake.callLog.firstIndex(of: "events"))
        let statusIndex = try #require(fake.callLog.firstIndex(of: "changesStatus"))
        #expect(eventsIndex < statusIndex)
        // §2 exact wire shape for the fetch.
        let statusCall = try #require(
            fake.recordedWireCalls.first { $0.method == "mobile.supermux.changes.status" }
        )
        #expect(statusCall.params == ["workspace_id": Self.workspaceID] as NSDictionary)

        // A poke for THIS workspace refetches…
        fake.changesStatusResponse = Self.statusB
        fake.emit(SupermuxMobileEvent(topic: .changesUpdated, workspaceID: Self.workspaceID))
        try await TestWait().until { store.status == Self.statusB }
        #expect(fake.changesStatusCallCount == 2)
    }

    @Test func ignoresChangesUpdatedForOtherWorkspaces() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        fake.emit(SupermuxMobileEvent(topic: .changesUpdated, workspaceID: "SOME-OTHER-WORKSPACE"))
        // Give the event a chance to (wrongly) trigger a refetch.
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.changesStatusCallCount == 1)
        #expect(store.status == Self.statusA)
    }

    @Test func fetchFailureSurfacesErrorAndNextEventRecovers() async throws {
        struct Boom: Error {}
        let fake = FakeSupermuxMacClient()
        fake.changesStatusError = Boom()
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.lastErrorDescription != nil }
        #expect(!store.hasLoaded)

        fake.changesStatusError = nil
        fake.changesStatusResponse = Self.statusA
        fake.emit(SupermuxMobileEvent(topic: .changesUpdated, workspaceID: Self.workspaceID))
        try await TestWait().until { store.hasLoaded }
        #expect(store.lastErrorDescription == nil)
    }

    // MARK: Capability gate

    @Test func withoutChangesCapabilityTheStoreIsInert() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(
            fake: fake,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: ["workspace.groups.v1"])
        )
        #expect(!store.showsChanges)
        await store.run()
        #expect(fake.callLog.isEmpty)
        #expect(store.status == nil)
    }

    // MARK: UI-04 — stage/unstage/discard state transitions + exact wire shapes

    @Test func stageSendsTheExactStageWireCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusB
        let store = makeStore(fake: fake)

        await store.stage(paths: ["src/app.swift"])
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.stage")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "paths": ["src/app.swift"],
        ] as NSDictionary)
        // The store refetches right after the mutation so the sections move
        // without waiting for the Mac's poke.
        #expect(fake.changesStatusCallCount == 1)
        #expect(store.status == Self.statusB)
        #expect(!store.isMutating)
    }

    @Test func stageAllSendsAllTrue() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusB
        let store = makeStore(fake: fake)

        await store.stageAll()
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.stage")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "all": true,
        ] as NSDictionary)
    }

    @Test func unstageSendsTheExactUnstageWireCall() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)

        await store.unstage(paths: ["staged.txt"])
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.unstage")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "paths": ["staged.txt"],
        ] as NSDictionary)
        #expect(store.status == Self.statusA)
    }

    @Test func discardSendsTheExactDiscardWireCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusB
        let store = makeStore(fake: fake)

        await store.discard(paths: ["src/app.swift"])
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.discard")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "paths": ["src/app.swift"],
        ] as NSDictionary)
        #expect(fake.changesStatusCallCount == 1)
        #expect(store.status == Self.statusB)
    }

    @Test func mutationFailureSurfacesErrorAndUnblocksFurtherActions() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStageError = MobileShellConnectionError.rpcError(
            "not_found", "Unknown path"
        )
        let store = makeStore(fake: fake)

        await store.stage(paths: ["ghost.txt"])
        #expect(store.lastErrorDescription != nil)
        #expect(!store.isMutating)
        // No refetch after a failed mutation.
        #expect(fake.changesStatusCallCount == 0)

        // The next successful action clears the error.
        fake.changesStageError = nil
        fake.changesStatusResponse = Self.statusA
        await store.stage(paths: ["notes.md"])
        #expect(store.lastErrorDescription == nil)
    }

    // MARK: Diff fetch

    @Test func loadDiffSendsTheExactDiffWireCallAndReturnsTheFixture() async throws {
        let fake = FakeSupermuxMacClient()
        let fixture = SupermuxDiffDTO(
            path: "src/app.swift",
            isBinary: false,
            diffText: "@@ -1 +1 @@\n-old\n+new",
            truncated: false
        )
        fake.changesDiffResponse = fixture
        let store = makeStore(fake: fake)

        let unstagedDiff = try await store.loadDiff(path: "src/app.swift", staged: false)
        #expect(unstagedDiff == fixture)
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.diff")
        // `staged` is omitted when false (the Mac defaults it to false).
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "path": "src/app.swift",
        ] as NSDictionary)

        _ = try await store.loadDiff(path: "staged.txt", staged: true)
        #expect(fake.recordedWireCalls[1].params == [
            "workspace_id": Self.workspaceID,
            "path": "staged.txt",
            "staged": true,
        ] as NSDictionary)
    }

    // MARK: Watch heartbeat (injected clock)

    @Test func heartbeatSendsWatchEnableAtTheSixtySecondCadence() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let gate = HeartbeatSleepGate()
        let store = makeStore(fake: fake, heartbeatSleep: { await gate.sleep($0) })
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        // Beat 1 fires immediately on run (screen appear).
        try await TestWait().until { self.watchCalls(fake).count == 1 }
        #expect(watchCalls(fake)[0] == [
            "workspace_id": Self.workspaceID,
            "enable": true,
        ] as NSDictionary)
        // The store then asks the clock for exactly the 60 s interval.
        try await TestWait().until { gate.requested.count == 1 }
        #expect(gate.requested == [SupermuxMobileChangesStore.heartbeatInterval])
        #expect(SupermuxMobileChangesStore.heartbeatInterval == .seconds(60))
        // No extra beat sneaks in while the clock is parked.
        #expect(watchCalls(fake).count == 1)

        // Advancing the clock by one interval yields exactly one more beat.
        gate.advance()
        try await TestWait().until { self.watchCalls(fake).count == 2 }
        #expect(watchCalls(fake)[1] == [
            "workspace_id": Self.workspaceID,
            "enable": true,
        ] as NSDictionary)
        try await TestWait().until { gate.requested.count == 2 }
        #expect(gate.requested == Array(
            repeating: SupermuxMobileChangesStore.heartbeatInterval,
            count: 2
        ))
        #expect(watchCalls(fake).count == 2)

        gate.advance()
        try await TestWait().until { self.watchCalls(fake).count == 3 }
    }

    @Test func cancellationSendsWatchDisable() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }

        try await TestWait().until { self.watchCalls(fake).count == 1 }
        runner.cancel()
        try await TestWait().until {
            self.watchCalls(fake).last == [
                "workspace_id": Self.workspaceID,
                "enable": false,
            ] as NSDictionary
        }
    }

    @Test func heartbeatFailureKeepsTheLoopAlive() async throws {
        struct Down: Error {}
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        fake.changesWatchError = Down()
        let gate = HeartbeatSleepGate()
        let store = makeStore(fake: fake, heartbeatSleep: { await gate.sleep($0) })
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { self.watchCalls(fake).count == 1 }
        // The failed beat still schedules the next one.
        try await TestWait().until { gate.requested.count == 1 }
        fake.changesWatchError = nil
        gate.advance()
        try await TestWait().until { self.watchCalls(fake).count == 2 }
    }

    // MARK: Response wire decoding (snake_case + unknown-field tolerance)

    @Test func watchAndAckResponsesDecodeFromWireJSON() throws {
        let watchJSON = Data(#"{"watching":true,"ttl_seconds":120,"future_field":1}"#.utf8)
        let watch = try JSONDecoder().decode(SupermuxChangesWatchResponse.self, from: watchJSON)
        #expect(watch.watching == true)
        #expect(watch.ttlSeconds == 120)

        let ackJSON = Data(#"{"ok":true,"future_field":"x"}"#.utf8)
        let ack = try JSONDecoder().decode(SupermuxChangesAckResponse.self, from: ackJSON)
        #expect(ack.ok == true)
    }
}

/// A controllable clock seam for the heartbeat: records every requested
/// sleep duration and suspends the caller until the test advances it (or the
/// task is cancelled, so cancelled runners never leak suspended children).
@MainActor
final class HeartbeatSleepGate {
    private(set) var requested: [Duration] = []
    private var pending: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    pending.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id) }
        }
    }

    /// Simulates the requested interval elapsing for the oldest sleeper.
    func advance() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume()
    }

    private func release(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        entry.continuation.resume()
    }
}

import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// The changes store's `changes.watch` behavior: the heartbeat fires
/// `{enable:true}` at the expected 60 s cadence through the injected clock
/// seam, `{enable:false}` goes out on cancellation, every send carries this
/// store's stable `client_id` (the Mac's multi-device refcount key), and
/// enable/disable delivery is FIFO-serialized so a torn-down session's
/// stale disable can never kill a fresh session's watch lease. Split from
/// `SupermuxMobileChangesStoreTests.swift` (file-length budget).
@MainActor
@Suite struct SupermuxMobileChangesStoreWatchTests {
    private static let workspaceID = "7B1D4C22-9F3A-4E0D-B7A1-5C6E8F0A2D33"

    private static let statusA = SupermuxChangesStatusDTO(
        workspaceId: workspaceID,
        isRepository: true,
        branch: "main"
    )

    private static let changesOnly = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.changesV1.rawValue]
    )

    private func makeStore(
        fake: FakeSupermuxMacClient,
        heartbeatSleep: ((Duration) async -> Void)? = nil
    ) -> SupermuxMobileChangesStore {
        SupermuxMobileChangesStore(
            client: fake,
            capabilities: Self.changesOnly,
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

    /// The store's per-session watch `client_id`, extracted from its first
    /// recorded `changes.watch` send (the id is random per store, so exact
    /// dictionary assertions build their expectation around it).
    private func watchClientID(_ fake: FakeSupermuxMacClient) throws -> String {
        try #require(watchCalls(fake).first?["client_id"] as? String)
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
        let clientID = try watchClientID(fake)
        #expect(watchCalls(fake)[0] == [
            "workspace_id": Self.workspaceID,
            "enable": true,
            "client_id": clientID,
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
            "client_id": clientID,
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
        let clientID = try watchClientID(fake)
        runner.cancel()
        try await TestWait().until {
            self.watchCalls(fake).last == [
                "workspace_id": Self.workspaceID,
                "enable": false,
                "client_id": clientID,
            ] as NSDictionary
        }
    }

    @Test func everyWatchSendCarriesTheSameStableClientID() async throws {
        // Multi-device refcount: the Mac counts watchers per `client_id`,
        // so BOTH the heartbeat's enable and the teardown's disable must
        // carry the SAME id — a missing id on either side falls back to the
        // legacy single-holder behavior where one device's disable kills
        // another device's live watcher.
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }

        try await TestWait().until { self.watchCalls(fake).count == 1 }
        runner.cancel()
        try await TestWait().until { self.watchCalls(fake).count == 2 }

        let calls = watchCalls(fake)
        let enableID = try #require(calls[0]["client_id"] as? String)
        let disableID = try #require(calls[1]["client_id"] as? String)
        #expect(calls[0]["enable"] as? Bool == true)
        #expect(calls[1]["enable"] as? Bool == false)
        #expect(!enableID.isEmpty)
        #expect(enableID == disableID, "enable and disable must identify the same watch session")

        // A DIFFERENT store (another device / another sheet) uses a
        // different id, so the Mac can tell the two sessions apart.
        let otherStore = makeStore(fake: fake)
        let otherRunner = Task { await otherStore.run() }
        defer { otherRunner.cancel() }
        try await TestWait().until { self.watchCalls(fake).count >= 3 }
        let otherID = try #require(watchCalls(fake)[2]["client_id"] as? String)
        #expect(otherID != enableID)
    }

    // MARK: Watch enable/disable ordering (#6)

    @Test func aStaleDisableIsDeliveredBeforeAFreshEnableNeverAfter() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)

        let runner1 = Task { await store.run() }
        try await TestWait().until { self.watchCalls(fake).count == 1 }
        let clientID = try watchClientID(fake)
        #expect(watchCalls(fake)[0] == [
            "workspace_id": Self.workspaceID,
            "enable": true,
            "client_id": clientID,
        ] as NSDictionary)

        // Make the teardown disable artificially slow — an unserialized
        // implementation would let a fresh session's fast enable race ahead
        // of it (push→pop→push killing the new watch lease).
        fake.changesWatchDisableArtificialDelay = .milliseconds(50)
        runner1.cancel()
        // `run()` returns right after enqueueing its disable send (fire and
        // forget, not awaited) — so awaiting the runner here only waits for
        // that enqueue, not for the (still in-flight, delayed) disable RPC.
        await runner1.value

        // Immediately start a NEW session on the SAME store (push→pop→push).
        let runner2 = Task { await store.run() }
        defer { runner2.cancel() }

        try await TestWait().until { self.watchCalls(fake).count == 3 }
        // FIFO: the stale disable must be delivered BEFORE the fresh
        // enable, never after.
        #expect(watchCalls(fake)[1] == [
            "workspace_id": Self.workspaceID,
            "enable": false,
            "client_id": clientID,
        ] as NSDictionary)
        #expect(watchCalls(fake)[2] == [
            "workspace_id": Self.workspaceID,
            "enable": true,
            "client_id": clientID,
        ] as NSDictionary)
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
    }}

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

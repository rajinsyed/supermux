import Foundation
import SupermuxMobileCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Logic-only coverage of ``SupermuxMobileChangesWatchRegistry``'s lease
/// contract (validation contract RPC-CHG-07): an entry not heartbeated for
/// the 120 s TTL is swept, a heartbeat inside the TTL keeps it alive,
/// `enable: false` stops immediately, and watcher events emit
/// `supermux.changes.updated {workspace_id}`.
///
/// Modeled on `SupermuxMobileAuthorizationTests`: injected clock, injected
/// watch-stream factory, injected emit sink — no FSEvents, no Ghostty
/// surfaces, no `Workspace`/`TabManager` construction, no real config.
@Suite(.serialized)
@MainActor
struct SupermuxMobileChangesWatchRegistryTests {
    /// A settable wall clock the registry reads through its injected closure.
    @MainActor
    private final class FakeClock {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func advance(by seconds: TimeInterval) { now += seconds }
    }

    /// Captures emitted events and hands out controllable watch streams.
    @MainActor
    private final class Harness {
        let clock = FakeClock()
        private(set) var emitted: [(topic: String, payload: [String: Any])] = []
        private(set) var continuationsByDirectory: [String: AsyncStream<Void>.Continuation] = [:]
        private(set) var registry: SupermuxMobileChangesWatchRegistry!

        init() {
            registry = SupermuxMobileChangesWatchRegistry(
                now: { [clock] in clock.now },
                makeChangeStream: { [weak self] directory in
                    AsyncStream { continuation in
                        self?.continuationsByDirectory[directory] = continuation
                    }
                },
                emit: { [weak self] topic, payload in
                    self?.emitted.append((topic, payload))
                },
                sweepsAutomatically: false
            )
        }
    }

    private struct TimedOut: Error {}

    /// Polls a main-actor condition (the watch task consumes its stream
    /// asynchronously) until it holds or the deadline passes.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - RPC-CHG-07: TTL expiry

    @Test func missedHeartbeatsPastTTLSweepTheWatcher() {
        let harness = Harness()
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo")
        #expect(harness.registry.watchedWorkspaceIds == ["ws-1"])

        harness.clock.advance(by: SupermuxMobileChangesWatchRegistry.ttl + 1)
        harness.registry.sweep()

        #expect(harness.registry.watchedWorkspaceIds.isEmpty)
    }

    @Test func heartbeatWithinTTLKeepsTheWatcherAlive() {
        let harness = Harness()
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo")

        // 100 s in (inside the TTL) the phone heartbeats by re-sending watch.
        harness.clock.advance(by: 100)
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo")

        // 100 s after the heartbeat the lease is still only 100 s old.
        harness.clock.advance(by: 100)
        harness.registry.sweep()
        #expect(harness.registry.watchedWorkspaceIds == ["ws-1"])

        // But past the TTL with no further heartbeat it is swept.
        harness.clock.advance(by: SupermuxMobileChangesWatchRegistry.ttl)
        harness.registry.sweep()
        #expect(harness.registry.watchedWorkspaceIds.isEmpty)
    }

    @Test func sweepOnlyRemovesExpiredLeases() {
        let harness = Harness()
        harness.registry.watch(workspaceId: "ws-old", directory: "/tmp/repo-old")
        harness.clock.advance(by: SupermuxMobileChangesWatchRegistry.ttl + 1)
        harness.registry.watch(workspaceId: "ws-fresh", directory: "/tmp/repo-fresh")

        harness.registry.sweep()

        #expect(harness.registry.watchedWorkspaceIds == ["ws-fresh"])
    }

    // MARK: - RPC-CHG-07: enable:false stops immediately

    @Test func unwatchStopsImmediately() {
        let harness = Harness()
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo")
        #expect(harness.registry.watchedWorkspaceIds == ["ws-1"])

        harness.registry.unwatch(workspaceId: "ws-1")

        #expect(harness.registry.watchedWorkspaceIds.isEmpty)
    }

    @Test func unwatchingAnUnknownWorkspaceIsANoOp() {
        let harness = Harness()
        harness.registry.unwatch(workspaceId: "ws-never-watched")
        #expect(harness.registry.watchedWorkspaceIds.isEmpty)
    }

    // MARK: - Event emission

    @Test func watcherEventsEmitChangesUpdatedWithWorkspaceId() async throws {
        let harness = Harness()
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo")
        let continuation = try #require(harness.continuationsByDirectory["/tmp/repo"])

        continuation.yield(())

        try await waitUntil { harness.emitted.count == 1 }
        #expect(harness.emitted[0].topic == SupermuxMobileTopic.changesUpdated.rawValue)
        #expect(harness.emitted[0].payload["workspace_id"] as? String == "ws-1")
    }

    @Test func heartbeatOnSameDirectoryKeepsTheSameStream() {
        let harness = Harness()
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo")
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo")

        // Only one stream was ever created for the directory: the second
        // watch renewed the lease instead of restarting the watcher.
        #expect(harness.continuationsByDirectory.count == 1)
        #expect(harness.registry.watchedWorkspaceIds == ["ws-1"])
    }

    @Test func changedDirectoryRestartsTheWatcher() {
        let harness = Harness()
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo-a")
        harness.registry.watch(workspaceId: "ws-1", directory: "/tmp/repo-b")

        #expect(harness.continuationsByDirectory.keys.sorted() == ["/tmp/repo-a", "/tmp/repo-b"])
        #expect(harness.registry.watchedWorkspaceIds == ["ws-1"])
    }
}

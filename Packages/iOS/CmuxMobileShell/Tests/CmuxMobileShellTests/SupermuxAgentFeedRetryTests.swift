// SUPERMUX:begin agent-feed-retry-backoff
import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// The resume dial storm (field, 2026-10-05 02:01:53Z): after 18.7 min in
/// the background a stuck dial failed, and while the peer engine held its
/// redial cooldown every new dial failed in under a millisecond. The agent
/// feed's refresh re-armed itself on each failure and fetched again at once:
/// 1,291 dial attempts to one Mac in 120 ms, until foreground recovery
/// retired the client.
///
/// Failure modes for a reconnect during the backoff (review finding I3),
/// listed before the fix:
/// 1. The new connection's refresh joins the old connection's task, which is
///    sleeping out its backoff and then ends because its client is stale:
///    the new connection's agent feed is never fetched.
/// 2. The old connection's task, when it ends, unregisters the new
///    connection's task, so the next trigger starts a second refresh beside
///    it.
@MainActor
@Suite struct SupermuxAgentFeedRetryTests {
    @Test func failingFeedRefreshDoesNotRedialInATightLoop() async throws {
        let attempts = PoolTransportAttemptCounter()
        let (store, client) = try Self.store(dialAttempts: attempts)

        store.scheduleForegroundAgentFeedRefresh(client: client)
        try await Task.sleep(for: .milliseconds(300))
        let attemptsIn300Milliseconds = attempts.count

        // Recovery retires the client, which is what ended the field storm.
        store.remoteClient = nil
        #expect(attemptsIn300Milliseconds >= 1)
        #expect(attemptsIn300Milliseconds <= 2, "dial attempts in 300 ms: \(attemptsIn300Milliseconds)")
    }

    @Test func failingFeedRefreshGivesUpUntilTheNextTrigger() async throws {
        let attempts = PoolTransportAttemptCounter()
        let clock = ImmediateRetryClock()
        let (store, client) = try Self.store(dialAttempts: attempts, clock: clock)

        store.scheduleForegroundAgentFeedRefresh(client: client)
        #expect(await SupermuxTerminalLaneRetryTests.eventually {
            await MainActor.run { store.agentFeedRefreshTasksByMac.isEmpty }
        })

        #expect(attempts.count == 3)
        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
        store.remoteClient = nil
    }

    @Test func aReconnectDuringTheBackoffRefreshesTheNewConnectionAtOnce() async throws {
        let oldAttempts = PoolTransportAttemptCounter()
        let (store, oldClient) = try Self.store(dialAttempts: oldAttempts)
        store.scheduleForegroundAgentFeedRefresh(client: oldClient)
        // The old connection's fetch fails; its refresh waits 1 s to retry.
        #expect(await SupermuxTerminalLaneRetryTests.eventually { oldAttempts.count == 1 })
        try await Task.sleep(for: .milliseconds(50))

        let newAttempts = PoolTransportAttemptCounter()
        let newClient = try Self.client(dialAttempts: newAttempts)
        store.remoteClient = newClient
        store.scheduleForegroundAgentFeedRefresh(client: newClient)

        #expect(
            await SupermuxTerminalLaneRetryTests.eventually(seconds: 0.6) { newAttempts.count >= 1 },
            "the new connection's refresh waited behind the old connection's backoff"
        )
        // The new refresh is now in its own backoff; the old one's end must
        // not unregister it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.agentFeedRefreshTasksByMac.count == 1, "the old refresh unregistered the new one")
        store.remoteClient = nil
    }

    private static func client(dialAttempts: PoolTransportAttemptCounter) throws -> MobileCoreRPCClient {
        let runtime = RoutingTestRuntime(
            transportFactory: FailingPoolTransportFactory(attempts: dialAttempts),
            supportedRouteKinds: [.iroh]
        )
        return MobileCoreRPCClient(runtime: runtime, route: try route(), ticket: try ticket())
    }

    private static func route() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            )
        )
    }

    private static func ticket() throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route()],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: nil
        )
    }

    private static func store(
        dialAttempts: PoolTransportAttemptCounter,
        clock: any Clock<Duration> = ContinuousClock()
    ) throws -> (MobileShellComposite, MobileCoreRPCClient) {
        let runtime = RoutingTestRuntime(
            transportFactory: FailingPoolTransportFactory(attempts: dialAttempts),
            supportedRouteKinds: [.iroh]
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            controlPlaneSchedulingClock: clock
        )
        let route = try route()
        let ticket = try ticket()
        let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket)
        store.remoteClient = client
        store.foregroundMacDeviceID = "test-mac"
        store.supportedHostCapabilities = [MobileShellComposite.agentFeedCapability]
        store.activeRoute = route
        store.activeTicket = ticket
        return (store, client)
    }
}

/// A clock whose sleeps return at once and are recorded.
final class ImmediateRetryClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant

    private let lock = NSLock()
    private var recorded: [Duration] = []

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    var sleeps: [Duration] { lock.withLock { recorded } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let milliseconds = (ContinuousClock.now.duration(to: deadline) / .milliseconds(1)).rounded()
        lock.withLock { recorded.append(.milliseconds(Int(milliseconds))) }
        try Task.checkCancellation()
    }
}
// SUPERMUX:end agent-feed-retry-backoff

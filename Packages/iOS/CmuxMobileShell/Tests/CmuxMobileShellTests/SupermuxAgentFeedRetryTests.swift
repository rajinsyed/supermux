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
        let route = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            )
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: nil
        )
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

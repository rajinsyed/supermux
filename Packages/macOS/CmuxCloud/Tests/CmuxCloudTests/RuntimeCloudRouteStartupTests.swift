// SUPERMUX:begin runtime-cloud-route-startup-regressions
@testable import CmuxCloud
import Foundation
import Testing

@Suite("Runtime cloud route startup")
struct RuntimeCloudRouteStartupTests {
    private static let ready = CloudWireGuardHub.Ready(
        socketPath: "/unused/test-hub.sock", routes: ["10.0.0.0/8", "fd00::/8"]
    )

    private func manager() async -> CloudMachineLinkManager {
        let manager = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        await manager.setPrivateAddresses(["10.1.1.1", "fd00::1"], for: "machine")
        return manager
    }

    @Test("Exhausted original budget recovers and admits a socket line within the renewed expiry")
    func recoveredSocketStartup() async throws {
        let harness = RouteHarness(probes: [.timeout(.seconds(60)), .answer(.seconds(3))])
        let result = try await (await manager()).startPrivateRoute(
            machineID: "machine", through: Self.ready, timeout: .seconds(60),
            operations: operations(harness), releaseLease: { await harness.release() }
        ) { route, timeout in
            #expect(route == "ws://[fd00::1]:1337/v1/link")
            return try await harness.socketLine(after: .seconds(4), timeout: timeout)
        }
        #expect(result == "SOCKET /test/link.sock")
        #expect(await harness.probeBudgets == [.seconds(60), .seconds(10)])
        #expect(await harness.startupBudgets == [.seconds(7)])
        #expect(await harness.refreshes == 1)
        #expect(await harness.releases == 0)
    }

    @Test("Ordinary probing and startup share the original expiry")
    func ordinaryBudget() async throws {
        let harness = RouteHarness(probes: [.answer(.seconds(7))])
        _ = try await (await manager()).startPrivateRoute(
            machineID: "machine", through: Self.ready, timeout: .seconds(60),
            operations: operations(harness), releaseLease: { await harness.release() }
        ) { _, timeout in
            try await harness.socketLine(after: .seconds(4), timeout: timeout)
        }
        #expect(await harness.probeBudgets == [.seconds(60)])
        #expect(await harness.startupBudgets == [.seconds(53)])
        #expect(await harness.refreshes == 0)
    }

    @Test("An enrollment refresh for missing routes spends, rather than renews, the original budget")
    func enrollmentRefreshBudget() async throws {
        let harness = RouteHarness(probes: [.answer(.seconds(7))])
        let unrelated = CloudWireGuardHub.Ready(socketPath: "/unused.sock", routes: ["192.168.0.0/16"])
        _ = try await (await manager()).startPrivateRoute(
            machineID: "machine", through: unrelated, timeout: .seconds(60),
            operations: operations(harness), releaseLease: { await harness.release() }
        ) { _, timeout in
            try await harness.socketLine(after: .seconds(4), timeout: timeout)
        }
        #expect(await harness.routingRefreshes == 1)
        #expect(await harness.probeBudgets == [.seconds(48)])
        #expect(await harness.startupBudgets == [.seconds(41)])
        #expect(await harness.refreshes == 0)
    }

    @Test("Startup cannot reset either an ordinary or a recovered expired deadline", arguments: [false, true])
    func expiredStartup(recovered: Bool) async throws {
        let probes: [RouteHarness.Probe] = recovered
            ? [.timeout(.seconds(60)), .answer(.seconds(10))] : [.answer(.seconds(60))]
        let harness = RouteHarness(probes: probes)
        await #expect(throws: SocketError.timedOut) {
            _ = try await (await manager()).startPrivateRoute(
                machineID: "machine", through: Self.ready, timeout: .seconds(60),
                operations: operations(harness), releaseLease: { await harness.release() }
            ) { _, timeout in
                do {
                    return try await harness.socketLine(after: .seconds(1), timeout: timeout)
                } catch {
                    await harness.release()
                    throw error
                }
            }
        }
        #expect(await harness.startupBudgets == [.zero])
        #expect(await harness.releases == 1)
    }

    @Test("A second unanswered probe fails and releases the selection lease without another recovery")
    func recoveryIsBounded() async throws {
        let harness = RouteHarness(probes: [.timeout(.seconds(60)), .timeout(.seconds(10))])
        let error = await #expect(throws: CloudPortForwardRelay.RelayError.self) {
            _ = try await (await manager()).startPrivateRoute(
                machineID: "machine", through: Self.ready, timeout: .seconds(60),
                operations: operations(harness), releaseLease: { await harness.release() }
            ) { _, timeout in try await harness.socketLine(after: .zero, timeout: timeout) }
        }
        if case .handshakeTimedOut(let timeout) = error {
            #expect(timeout == .seconds(10))
        } else {
            Issue.record("Expected the retry's handshake timeout")
        }
        #expect(await harness.probeBudgets == [.seconds(60), .seconds(10)])
        #expect(await harness.refreshes == 1)
        #expect(await harness.releases == 1)
        #expect(await harness.startupBudgets.isEmpty)
    }

    @Test("Cancellation during selection or recovery releases the lease before startup", arguments: [false, true])
    func selectionCancellation(duringRecovery: Bool) async throws {
        let gate = RouteGate()
        let harness = RouteHarness(probes: duringRecovery ? [.timeout(.seconds(60))] : [.answer(.seconds(1))])
        let manager = await manager()
        let dependencies = operations(harness, probeGate: duringRecovery ? nil : gate, refreshGate: duringRecovery ? gate : nil)
        let task = Task {
            try await manager.startPrivateRoute(
                machineID: "machine", through: Self.ready, timeout: .seconds(60),
                operations: dependencies, releaseLease: { await harness.release() }
            ) { _, timeout in try await harness.socketLine(after: .zero, timeout: timeout) }
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await harness.probeBudgets.count == 1)
        #expect(await harness.startupBudgets.isEmpty)
        #expect(await harness.releases == 1)
    }

    @Test("Cancellation after lease transfer is owned by startup, with no duplicate release")
    func startupCancellation() async throws {
        let gate = RouteGate()
        let harness = RouteHarness(probes: [.answer(.seconds(1))])
        let manager = await manager()
        let task = Task {
            try await manager.startPrivateRoute(
                machineID: "machine", through: Self.ready, timeout: .seconds(60),
                operations: operations(harness), releaseLease: { await harness.release() }
            ) { _, timeout in
                await gate.enter()
                do {
                    try Task.checkCancellation()
                    return try await harness.socketLine(after: .zero, timeout: timeout)
                } catch {
                    await harness.release()
                    throw error
                }
            }
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await harness.releases == 1)
    }

    private func operations(
        _ harness: RouteHarness, probeGate: RouteGate? = nil, refreshGate: RouteGate? = nil
    ) -> CloudMachineLinkManagerPrivateRouteOperations {
        CloudMachineLinkManagerPrivateRouteOperations(
            now: { await harness.now },
            probe: { _, target, timeout in
                #expect(target.host == "10.1.1.1")
                #expect(target.fallbackHosts == ["fd00::1"])
                let host = try await harness.probe(timeout: timeout)
                await probeGate?.enter()
                return host
            },
            readyRouting: { _ in await harness.routingRefresh(); return Self.ready },
            refreshUnanswered: {
                await harness.refresh()
                await refreshGate?.enter()
                return Self.ready
            }
        )
    }
}

private enum SocketError: Error, Equatable { case timedOut }

/// Virtual monotonic time drives both the connector and the socket-line collaborator.
private actor RouteHarness {
    enum Probe: Sendable { case timeout(Duration), answer(Duration) }
    var now = ContinuousClock.now
    var probeBudgets: [Duration?] = []
    var startupBudgets: [Duration] = []
    var refreshes = 0
    var routingRefreshes = 0
    var releases = 0
    private var probes: [Probe]

    init(probes: [Probe]) { self.probes = probes }

    func probe(timeout: Duration?) throws -> String {
        probeBudgets.append(timeout)
        guard !probes.isEmpty else { throw CloudPortForwardRelay.RelayError.handshakeTimedOut(timeout ?? .zero) }
        switch probes.removeFirst() {
        case .timeout(let elapsed):
            now += elapsed
            throw CloudPortForwardRelay.RelayError.handshakeTimedOut(timeout ?? .zero)
        case .answer(let elapsed):
            now += elapsed
            return "fd00::1"
        }
    }

    func socketLine(after delay: Duration, timeout: Duration) throws -> String {
        startupBudgets.append(timeout)
        guard delay < timeout else { throw SocketError.timedOut }
        now += delay
        return "SOCKET /test/link.sock"
    }

    func refresh() { refreshes += 1; now += .seconds(2) }
    func routingRefresh() { routingRefreshes += 1; now += .seconds(12) }
    func release() { releases += 1 }
}

private actor RouteGate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { blocked = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }

    func open() { blocked?.resume(); blocked = nil }
}
// SUPERMUX:end runtime-cloud-route-startup-regressions

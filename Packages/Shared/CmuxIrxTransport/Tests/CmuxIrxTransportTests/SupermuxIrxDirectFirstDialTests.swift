// SUPERMUX:begin route-direct-lane (a direct-first dial: a direct-only lane races the relay — see SUPERMUX-TOUCHPOINTS.md)
import Darwin
import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// A dial to another Mac races a direct-only "lane" endpoint (same identity,
/// relays disabled, the peer's LAN and Tailscale addresses) against the relay
/// dial, direct first. Field evidence (2026-10-05): every Mac-to-Mac session
/// started on the Tokyo relay (~240 ms a keystroke).
///
/// Ways the race could get it wrong:
/// 1. Both legs succeed and both connections reach admission; the host keeps
///    one session per device and supersedes the other, so the link loops.
///    Exactly one value may come out; the other is closed before admission.
/// 2. The relay finishing first wins although direct answers within its
///    deadline (the user wants direct whenever it works).
/// 3. A blackholed direct address holds the dial until QUIC gives up instead
///    of using the relay at the direct deadline.
/// 4. With no direct address the relay still waits out the head start.
/// 5. A direct leg that fails fast still makes the relay wait the head start.
/// 6. The relay is dialed although direct won inside the head start (a wasted
///    relay handshake and journal noise on the host).
/// 7. A direct success after its deadline (the cancel lost the race) leaks.
/// 8. A relay failure ends the dial while direct is still trying.
/// 9. Both legs fail and the dial hangs, or reports the direct leg's error
///    (the link classifies the relay dial's failure, as upstream).
/// 10. The caller is cancelled (the link tore down) and the legs keep running,
///     or a value that arrives afterwards leaks.
/// 11. A relay connection held while direct was still trying is not used when
///     direct then fails.
///
/// On live iroh endpoints (the "relay" leg is a second endpoint of the same
/// identity behind a link with 120 ms each way; the "direct" leg is the lane
/// through a link that can be cut):
/// - L1. The lane reaches the host directly, one path, no relay path, while
///   the other endpoint of the same identity keeps its own session.
/// - L2. The race lands on direct and the host admits exactly once.
/// - L3. With the direct path cut the race lands on the relay at the direct
///   deadline, and the host admits exactly once.
/// - L4. A route probe completes a handshake the host never admits, and fails
///   within its deadline when the path is cut.
/// - L5. A direct session whose path is cut stops answering within a few
///   seconds (the evidence for falling back to the relay).
/// - L6 (opt-in, public relays: `CMUX_IROH_PUBLIC_RELAY_TEST=1`). With the
///   direct address blackholed the race lands on a real relay path; with that
///   relay session admitted and authorized, the lane of the same identity
///   still starts direct (the shared endpoint's selected path does not reach it).
@Suite("direct-first dial")
struct SupermuxIrxDirectFirstDialTests {
    typealias State = SupermuxIrxDialRaceState<Int>

    struct Named: Error, Equatable {
        let name: String
    }

    private func describe(_ effects: [State.Effect]) -> [String] {
        effects.map { effect in
            switch effect {
            case .startRelay: return "startRelay"
            case .cancelDirect: return "cancelDirect"
            case .cancelRelay: return "cancelRelay"
            case .discard(let value): return "discard(\(value))"
            case .finish(.success(let winner)): return "finish(\(winner.leg.rawValue) \(winner.value))"
            case .finish(.failure(let error as Named)): return "finish(error \(error.name))"
            case .finish(.failure(let error)): return "finish(error \(type(of: error)))"
            }
        }
    }

    private func started(hasDirect: Bool = true) -> (State, [String]) {
        var state = State(hasDirect: hasDirect)
        let effects = describe(state.start())
        return (state, effects)
    }

    // MARK: - The race's decisions

    @Test("4. no direct address: the relay starts at once")
    func noDirectStartsRelayAtOnce() {
        var (state, first) = started(hasDirect: false)
        #expect(first == ["startRelay"])
        #expect(describe(state.handle(.relaySucceeded(2))) == ["finish(relay 2)"])
    }

    @Test("6. direct inside the head start: the relay is never dialed")
    func directInsideHeadStart() {
        var (state, first) = started()
        #expect(first == [])
        #expect(describe(state.handle(.directSucceeded(1))) == ["finish(direct 1)"])
        #expect(describe(state.handle(.headStartElapsed)) == [])
        #expect(describe(state.handle(.directDeadlineElapsed)) == [])
    }

    @Test("1. both succeed: direct wins, the relay is cancelled and a late relay closed")
    func directWinsAfterHeadStart() {
        var (state, _) = started()
        #expect(describe(state.handle(.headStartElapsed)) == ["startRelay"])
        #expect(describe(state.handle(.directSucceeded(1))) == ["cancelRelay", "finish(direct 1)"])
        #expect(describe(state.handle(.relaySucceeded(2))) == ["discard(2)"])
    }

    @Test("2. a relay that finishes first is held while direct is still trying")
    func relayFirstIsHeld() {
        var (state, _) = started()
        _ = state.handle(.headStartElapsed)
        #expect(describe(state.handle(.relaySucceeded(2))) == [])
        #expect(describe(state.handle(.directSucceeded(1))) == ["discard(2)", "finish(direct 1)"])
    }

    @Test("11. a held relay is used once direct fails")
    func heldRelayUsedWhenDirectFails() {
        var (state, _) = started()
        _ = state.handle(.headStartElapsed)
        _ = state.handle(.relaySucceeded(2))
        #expect(describe(state.handle(.directFailed(Named(name: "unreachable")))) == ["finish(relay 2)"])
    }

    @Test("3 and 7. at the direct deadline direct is cancelled; the relay wins; a late direct is closed")
    func directDeadline() {
        var (state, _) = started()
        _ = state.handle(.headStartElapsed)
        #expect(describe(state.handle(.directDeadlineElapsed)) == ["cancelDirect"])
        #expect(describe(state.handle(.relaySucceeded(2))) == ["finish(relay 2)"])
        #expect(describe(state.handle(.directSucceeded(1))) == ["discard(1)"])

        var held = State(hasDirect: true)
        _ = held.start()
        _ = held.handle(.headStartElapsed)
        _ = held.handle(.relaySucceeded(2))
        #expect(describe(held.handle(.directDeadlineElapsed)) == ["cancelDirect", "finish(relay 2)"])
    }

    @Test("5. a direct leg that fails fast starts the relay at once, once")
    func directFailsBeforeHeadStart() {
        var (state, _) = started()
        #expect(describe(state.handle(.directFailed(Named(name: "refused")))) == ["startRelay"])
        #expect(describe(state.handle(.headStartElapsed)) == [])
        #expect(describe(state.handle(.directDeadlineElapsed)) == [])
        #expect(describe(state.handle(.relaySucceeded(2))) == ["finish(relay 2)"])
    }

    @Test("8. a relay failure waits for direct")
    func relayFailureWaitsForDirect() {
        var (state, _) = started()
        _ = state.handle(.headStartElapsed)
        #expect(describe(state.handle(.relayFailed(Named(name: "relay-down")))) == [])
        #expect(describe(state.handle(.directSucceeded(1))) == ["finish(direct 1)"])
    }

    @Test("9. both fail: the relay's error, in either order")
    func bothFail() {
        var (state, _) = started()
        _ = state.handle(.headStartElapsed)
        #expect(describe(state.handle(.directFailed(Named(name: "unreachable")))) == [])
        #expect(describe(state.handle(.relayFailed(Named(name: "relay-down")))) == ["finish(error relay-down)"])

        var reversed = State(hasDirect: true)
        _ = reversed.start()
        _ = reversed.handle(.headStartElapsed)
        _ = reversed.handle(.relayFailed(Named(name: "relay-down")))
        #expect(describe(reversed.handle(.directFailed(Named(name: "unreachable")))) == ["finish(error relay-down)"])
    }

    @Test("10. cancelled: both legs stop, a held or late value is closed")
    func cancelled() {
        var (state, _) = started()
        _ = state.handle(.headStartElapsed)
        _ = state.handle(.relaySucceeded(2))
        #expect(describe(state.handle(.cancelled)) == ["cancelDirect", "discard(2)", "finish(error CancellationError)"])
        #expect(describe(state.handle(.directSucceeded(1))) == ["discard(1)"])

        var early = State(hasDirect: true)
        _ = early.start()
        #expect(describe(early.handle(.cancelled)) == ["cancelDirect", "finish(error CancellationError)"])
        #expect(describe(early.handle(.headStartElapsed)) == [], "no relay after a cancel")
    }

    // MARK: - The race running

    @Test("6. running: direct answers at once, the relay leg is never called", .timeLimit(.minutes(1)))
    func runningDirectWins() async throws {
        let relay = FakeLeg(.value(2, after: .milliseconds(10)))
        let outcome = try await SupermuxIrxDirectFirstDial.race(
            timing: .init(headStart: .milliseconds(200), directDeadline: .seconds(1)),
            direct: { 1 }, relay: { try await relay.run() }, discard: { _ in })
        #expect(outcome.value == 1 && outcome.leg == .direct)
        try await Task.sleep(for: .milliseconds(300))
        #expect(relay.calls == 0)
    }

    @Test("3. running: a blackholed direct leg is cancelled at its deadline and the relay wins", .timeLimit(.minutes(1)))
    func runningBlackholedDirect() async throws {
        let direct = FakeLeg(.hang)
        let started = ContinuousClock.now
        let outcome = try await SupermuxIrxDirectFirstDial.race(
            timing: .init(headStart: .milliseconds(20), directDeadline: .milliseconds(300)),
            direct: { try await direct.run() },
            relay: { try await FakeLeg(.value(2, after: .milliseconds(30))).run() }, discard: { _ in })
        let elapsed = started.duration(to: .now)
        #expect(outcome.value == 2 && outcome.leg == .relay)
        #expect(elapsed >= .milliseconds(300) && elapsed < .seconds(2), "\(elapsed)")
        try await waitUntil { direct.cancelled }
    }

    @Test("10. running: a cancelled caller cancels both legs and closes a value that arrives later", .timeLimit(.minutes(1)))
    func runningCancelled() async throws {
        let direct = FakeLeg(.ignoresCancel(1, after: .milliseconds(150)))
        let relay = FakeLeg(.hang)
        let discards = Recorder()
        let dial = Task {
            try await SupermuxIrxDirectFirstDial.race(
                timing: .init(headStart: .milliseconds(10), directDeadline: .seconds(5)),
                direct: { try await direct.run() }, relay: { try await relay.run() },
                discard: { discards.append($0) })
        }
        try await waitUntil { relay.calls == 1 }
        dial.cancel()
        await #expect(throws: CancellationError.self) { _ = try await dial.value }
        try await waitUntil { relay.cancelled && direct.cancelled }
        try await waitUntil { discards.values == [1] }
    }

    // MARK: - Live endpoints

    @Test("L1. the lane reaches the host directly while the same identity keeps another session", .timeLimit(.minutes(1)))
    func laneReachesHostDirectly() async throws {
        let rig = try await LiveRig.make()
        let main = try await rig.admit(rig.dialMain())
        let lane = try await rig.admit(rig.dialLane())
        let sample = try #require(lane.supermuxSelectedPathSample())
        #expect(!sample.isRelay && !sample.hasRelayPath && sample.pathCount == 1, "\(sample)")
        #expect(sample.remoteAddress == rig.directLink.clientFacingAddress)
        #expect(await main.probeLiveness(deadline: .seconds(3)), "the other endpoint's session still answers")
        #expect(await lane.probeLiveness(deadline: .seconds(3)))
        #expect(rig.host.admitted == 2)
        await rig.shutDown()
    }

    @Test("L2. the race lands on direct and the host admits once", .timeLimit(.minutes(1)))
    func liveRaceLandsDirect() async throws {
        let rig = try await LiveRig.make()
        let outcome = try await rig.race()
        #expect(outcome.leg == .direct)
        #expect(outcome.value.supermuxSelectedPathSample()?.remoteAddress == rig.directLink.clientFacingAddress)
        _ = try await rig.admit(outcome.value)
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.host.admitted == 1)
        #expect(rig.host.incoming == 1, "the relay leg never dialed")
        await rig.shutDown()
    }

    @Test("L3. with the direct path cut the race lands on the relay at the deadline; one admission", .timeLimit(.minutes(1)))
    func liveRaceFallsBackToRelay() async throws {
        let rig = try await LiveRig.make()
        rig.directLink.blocked = true
        let started = ContinuousClock.now
        let outcome = try await rig.race()
        let elapsed = started.duration(to: .now)
        #expect(outcome.leg == .relay)
        #expect(outcome.value.supermuxSelectedPathSample()?.remoteAddress == rig.relayLink.clientFacingAddress)
        #expect(elapsed >= .milliseconds(1400) && elapsed <= .milliseconds(2500), "fell back after \(elapsed)")
        _ = try await rig.admit(outcome.value)
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.host.admitted == 1)
        print("direct-first dial with the direct path cut: relay after \(elapsed), \(outcome.journalFields)")
        await rig.shutDown()
    }

    @Test("L4. a probe completes a handshake the host never admits; a cut path fails within the deadline", .timeLimit(.minutes(1)))
    func liveProbe() async throws {
        let rig = try await LiveRig.make()
        let took = await SupermuxIrxDirectFirstDial.probe(
            lane: rig.lane, peerEndpointIDHex: rig.host.endpointIDHex,
            addresses: [rig.directLink.clientFacingAddress], deadline: .milliseconds(1500))
        #expect(took != nil)
        try await waitUntil { rig.host.incoming == 1 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.host.admitted == 0, "a probe is never admitted")

        rig.directLink.blocked = true
        let started = ContinuousClock.now
        let cut = await SupermuxIrxDirectFirstDial.probe(
            lane: rig.lane, peerEndpointIDHex: rig.host.endpointIDHex,
            addresses: [rig.directLink.clientFacingAddress], deadline: .milliseconds(1500))
        let elapsed = started.duration(to: .now)
        #expect(cut == nil)
        #expect(elapsed < .milliseconds(2200), "the probe outlived its deadline: \(elapsed)")
        print("route probe: direct \(String(describing: took)), cut path gave up after \(elapsed)")
        await rig.shutDown()
    }

    @Test("L5. a direct session whose path is cut stops answering within a few seconds", .timeLimit(.minutes(1)))
    func liveCutSessionStopsAnswering() async throws {
        let rig = try await LiveRig.make()
        let lane = try await rig.admit(rig.dialLane())
        #expect(await SupermuxIrxDirectFirstDial.answers(lane))
        rig.directLink.blocked = true
        try await Task.sleep(for: SupermuxIrxDirectFirstDial.quietBeforeProbe + .milliseconds(100))
        let started = ContinuousClock.now
        let answered = await SupermuxIrxDirectFirstDial.answers(lane)
        let elapsed = started.duration(to: .now)
        #expect(!answered)
        #expect(elapsed < .milliseconds(1600), "the liveness probe outlived its deadline: \(elapsed)")
        rig.directLink.blocked = false
        #expect(await lane.probeLiveness(deadline: .seconds(3)), "the path came back")
        #expect(await SupermuxIrxDirectFirstDial.answers(lane))
        await rig.shutDown()
    }

    @Test("L6. public relay: a blackholed direct address lands on the relay; the lane still starts direct beside it",
          .enabled(if: ProcessInfo.processInfo.environment["CMUX_IROH_PUBLIC_RELAY_TEST"] == "1"),
          .timeLimit(.minutes(1)))
    func publicRelayRace() async throws {
        let journal = IrxLiveTestSupport.journal()
        func relayed(_ seed: Data) async throws -> Endpoint {
            try await Endpoint.bind(options: EndpointOptions(
                preset: presetMinimal(), secretKey: seed, alpns: [IrxProtocol().alpnData],
                relayMode: RelayMode.defaultMode(), portMappingEnabled: false,
                deferNatTraversalUntilAuthorized: true,
                initialMaxConcurrentBiStreams: 8, initialMaxConcurrentUniStreams: 0))
        }
        let seed = IrxLiveTestSupport.identitySeed()
        let hostEndpoint = try await relayed(IrxLiveTestSupport.identitySeed())
        let main = try await relayed(seed)
        await hostEndpoint.online()
        await main.online()
        let host = CountingHost(endpoint: hostEndpoint)
        host.start(journal: journal)
        let relayURL = try #require(hostEndpoint.addr().relayUrl())
        let hostDirect = IrxLiveTestSupport.loopbackAddr(of: hostEndpoint).directAddresses()
            .filter { $0.hasPrefix("127.0.0.1:") }
        let hostPort = try #require(hostDirect.first?.split(separator: ":").last.flatMap { UInt16($0) })
        let blackhole = try SupermuxShapedUDPLink(hostPort: hostPort, shape: .init(
            bytesPerSecond: 1_000_000, oneWayDelay: 0, queueBytes: 100_000))
        blackhole.blocked = true
        let lane = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
            identity: IrxIdentity(privateKeyData: seed, deviceID: "lane-relay-test", appInstanceID: "lane-relay-test"),
            pathMode: .directOnly, initialRemoteBiStreams: 0, initialRemoteUniStreams: 0), journal: journal)
        let hostID = hostEndpoint.id()

        let started = ContinuousClock.now
        let outcome = try await SupermuxIrxDirectFirstDial.race(
            timing: .standard,
            direct: { try await lane.dial(address: EndpointAddr(id: hostID, relayUrl: nil,
                addresses: [blackhole.clientFacingAddress]), credentials: []) },
            relay: {
                IrxConnection(connection: try await main.connect(
                    addr: EndpointAddr(id: hostID, relayUrl: relayURL, addresses: []), alpn: IrxProtocol().alpnData),
                    role: .dialer, journal: journal)
            },
            discard: { SupermuxIrxDirectFirstDial.close($0, reason: "supermux-dial-race-lost") })
        let elapsed = started.duration(to: .now)
        #expect(outcome.leg == .relay)
        let relayedSample = try #require(outcome.value.supermuxSelectedPathSample())
        #expect(relayedSample.isRelay, "\(relayedSample)")
        _ = try await IrxAdmission().performClient(connection: outcome.value, grantJWS: "good-grant", journal: journal)
        await outcome.value.authorizeDirectPaths()
        print("public relay race with a blackholed direct address: \(outcome.journalFields) after \(elapsed), \(relayedSample)")

        let direct = try await lane.dial(address: EndpointAddr(id: hostID, relayUrl: nil, addresses: hostDirect), credentials: [])
        let laneSample = try #require(direct.supermuxSelectedPathSample())
        #expect(!laneSample.isRelay && !laneSample.hasRelayPath, "\(laneSample)")
        #expect(hostDirect.contains(laneSample.remoteAddress), "\(laneSample)")
        _ = try await IrxAdmission().performClient(connection: direct, grantJWS: "good-grant", journal: journal)
        #expect(await outcome.value.probeLiveness(deadline: .seconds(5)), "the relayed session still answers")
        try await waitUntil { host.admitted == 2 }
        print("lane beside the relayed session: \(laneSample)")

        await outcome.value.close(code: .userRequested, origin: .local)
        await direct.close(code: .userRequested, origin: .local)
        blackhole.stop()
        await lane.deactivate()
        await host.stop()
        try await main.close()
    }
}

// MARK: - Fakes

/// One leg of a race: answers, fails, hangs until cancelled, or ignores
/// cancellation and answers anyway.
private final class FakeLeg: @unchecked Sendable {
    enum Behavior {
        case value(Int, after: Duration)
        case hang
        case ignoresCancel(Int, after: Duration)
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var callCount = 0
    private var wasCancelled = false

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var calls: Int { lock.withLock { callCount } }
    var cancelled: Bool { lock.withLock { wasCancelled } }

    func run() async throws -> Int {
        lock.withLock { callCount += 1 }
        return try await withTaskCancellationHandler {
            switch behavior {
            case let .value(value, after):
                try await Task.sleep(for: after)
                return value
            case .hang:
                try await Task.sleep(for: .seconds(3_600))
                return -1
            case let .ignoresCancel(value, after):
                return await Task.detached {
                    try? await Task.sleep(for: after)
                    return value
                }.value
            }
        } onCancel: {
            lock.withLock { wasCancelled = true }
        }
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    var values: [Int] { lock.withLock { recorded } }

    func append(_ value: Int) {
        lock.withLock { recorded.append(value) }
    }
}

private func waitUntil(_ condition: @escaping () -> Bool, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: - Live rig

/// A host that admits every irx connection that sends a hello and serves its
/// keepalive lane, counting what reached it.
private final class CountingHost: @unchecked Sendable {
    let endpoint: Endpoint
    let endpointIDHex: String
    private let lock = NSLock()
    private var incomingCount = 0
    private var admittedCount = 0
    private var rejectedCount = 0
    private var connections: [IrxConnection] = []
    private var loop: Task<Void, Never>?

    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        endpointIDHex = endpoint.id().toBytes().map { String(format: "%02x", $0) }.joined()
    }

    var incoming: Int { lock.withLock { incomingCount } }
    var admitted: Int { lock.withLock { admittedCount } }
    var rejected: Int { lock.withLock { rejectedCount } }

    func start(journal: IrxJournal) {
        loop = Task { [endpoint] in
            while let incoming = await endpoint.acceptNext() {
                self.lock.withLock { self.incomingCount += 1 }
                Task {
                    guard let native = try? await incoming.accept().connect() else { return }
                    let irx = IrxConnection(connection: native, role: .acceptor, journal: journal)
                    self.lock.withLock { self.connections.append(irx) }
                    guard await IrxAdmission().performServer(
                        connection: irx, judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                        journal: journal) != nil else {
                        self.lock.withLock { self.rejectedCount += 1 }
                        return
                    }
                    self.lock.withLock { self.admittedCount += 1 }
                    while let lane = await irx.acceptLane() {
                        if lane.descriptor.lane == .keepalive { _ = irx.respondKeepalive(on: lane) }
                    }
                }
            }
        }
    }

    func stop() async {
        loop?.cancel()
        for connection in lock.withLock({ connections }) {
            await connection.close(code: .userRequested, origin: .local)
        }
        try? await endpoint.close()
    }
}

/// A host; a client identity with two endpoints (the main one behind a slow
/// "relay" link, the direct-only lane behind a link that can be cut).
private final class LiveRig: Sendable {
    let host: CountingHost
    let main: IrxEndpointSupervisor
    let lane: IrxEndpointSupervisor
    let relayLink: SupermuxShapedUDPLink
    let directLink: SupermuxShapedUDPLink
    let journal: IrxJournal

    private init(host: CountingHost, main: IrxEndpointSupervisor, lane: IrxEndpointSupervisor,
                 relayLink: SupermuxShapedUDPLink, directLink: SupermuxShapedUDPLink, journal: IrxJournal) {
        self.host = host
        self.main = main
        self.lane = lane
        self.relayLink = relayLink
        self.directLink = directLink
        self.journal = journal
    }

    static func make() async throws -> LiveRig {
        let journal = IrxLiveTestSupport.journal()
        let hostEndpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(), bindAddr: "127.0.0.1:0", secretKey: IrxLiveTestSupport.identitySeed(),
            alpns: [IrxProtocol().alpnData], relayMode: RelayMode.disabled(), portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 8, initialMaxConcurrentUniStreams: 0))
        let host = CountingHost(endpoint: hostEndpoint)
        host.start(journal: journal)
        let hostAddress = try #require(IrxLiveTestSupport.loopbackAddr(of: hostEndpoint).directAddresses().first)
        let hostPort = try #require(hostAddress.split(separator: ":").last.flatMap { UInt16($0) })
        let relayLink = try SupermuxShapedUDPLink(hostPort: hostPort, shape: .init(
            bytesPerSecond: 10_000_000, oneWayDelay: 0.12, queueBytes: 1_000_000))
        let directLink = try SupermuxShapedUDPLink(hostPort: hostPort, shape: .init(
            bytesPerSecond: 100_000_000, oneWayDelay: 0, queueBytes: 4_000_000))
        let seed = IrxLiveTestSupport.identitySeed()
        func supervisor() -> IrxEndpointSupervisor {
            IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
                identity: IrxIdentity(privateKeyData: seed, deviceID: "lane-test", appInstanceID: "lane-test"),
                pathMode: .directOnly, preferredBindAddress: "127.0.0.1:0",
                initialRemoteBiStreams: 0, initialRemoteUniStreams: 0), journal: journal)
        }
        return LiveRig(host: host, main: supervisor(), lane: supervisor(),
                       relayLink: relayLink, directLink: directLink, journal: journal)
    }

    private func address(_ link: SupermuxShapedUDPLink) throws -> EndpointAddr {
        EndpointAddr(id: try EndpointId.fromString(s: host.endpointIDHex), relayUrl: nil,
                     addresses: [link.clientFacingAddress])
    }

    func dialMain() async throws -> IrxConnection {
        try await main.dial(address: address(relayLink), credentials: [])
    }

    func dialLane() async throws -> IrxConnection {
        try await lane.dial(address: address(directLink), credentials: [])
    }

    func race() async throws -> SupermuxIrxDirectFirstDial.Outcome<IrxConnection> {
        try await SupermuxIrxDirectFirstDial.dial(
            lane: lane, directAddresses: [directLink.clientFacingAddress],
            main: main, relayAddress: address(relayLink), credentials: [])
    }

    func admit(_ connection: IrxConnection) async throws -> IrxConnection {
        _ = try await IrxAdmission().performClient(connection: connection, grantJWS: "good-grant", journal: journal)
        return connection
    }

    func shutDown() async {
        await host.stop()
        await main.deactivate()
        await lane.deactivate()
        relayLink.stop()
        directLink.stop()
    }
}
// SUPERMUX:end route-direct-lane

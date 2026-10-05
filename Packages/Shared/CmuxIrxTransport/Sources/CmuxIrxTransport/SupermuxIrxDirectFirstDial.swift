// SUPERMUX:begin route-direct-lane (a direct-first dial: a direct-only lane races the relay — see SUPERMUX-TOUCHPOINTS.md)
public import Foundation
public import IrohLib

/// Which leg of a direct-first dial produced the connection.
public enum SupermuxIrxDialLeg: String, Sendable {
    /// The direct lane: a relay-less endpoint with the same identity.
    case direct
    /// The ordinary dial through the relay.
    case relay
}

/// A dial that prefers a direct path: the peer's direct addresses on a
/// direct-only "lane" endpoint (same identity, relays disabled), raced
/// against the ordinary relay dial.
///
/// The lane starts at once; the relay after ``Timing/headStart``, or as soon
/// as the lane fails. Direct wins whenever it connects before
/// ``Timing/directDeadline``: a relay connection that is ready first is held
/// until then. Exactly one connection comes out; the other leg is cancelled,
/// and a connection it still produces is closed before anything is sent on
/// it, so the host admits one session.
///
/// The lane never authorizes NAT traversal, so iroh never health-checks its
/// path and never builds the 5–300 s block it keeps for a stalled direct path
/// on the shared endpoint; and its per-peer state has no selected path, so
/// the supplied addresses are what the first packets go to.
public enum SupermuxIrxDirectFirstDial {
    public struct Timing: Equatable, Sendable {
        /// How long the lane runs alone.
        public var headStart: Duration
        /// How long the lane may take before the relay is used.
        public var directDeadline: Duration

        public init(headStart: Duration, directDeadline: Duration) {
            self.headStart = headStart
            self.directDeadline = directDeadline
        }

        public static let standard = Timing(headStart: .milliseconds(250), directDeadline: .milliseconds(1500))
    }

    /// The winning value, its leg, and what each leg did (for the journal).
    public struct Outcome<Value: Sendable>: Sendable {
        public let value: Value
        public let leg: SupermuxIrxDialLeg
        /// `direct` and `relay`: `none`, `ok <ms>`, `failed <ms>`, `timeout`,
        /// `held`, `not-started` or `cancelled`.
        public let journalFields: [String: String]
    }

    /// How long a direct session may be quiet before ``answers(_:quietFor:probeDeadline:)`` probes it.
    public static let quietBeforeProbe: Duration = .seconds(2)
    /// How long that probe waits.
    public static let livenessProbeDeadline: Duration = .seconds(1)

    /// Races `direct` (if any) against `relay` under `timing`. `discard`
    /// closes a value that lost; `sleep` is the timer (tests replace it).
    public static func race<Value: Sendable>(
        timing: Timing,
        direct: (@Sendable () async throws -> Value)?,
        relay: @escaping @Sendable () async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Outcome<Value> {
        let driver = SupermuxIrxDialRaceDriver(
            timing: timing, direct: direct, relay: relay, discard: discard, sleep: sleep)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                driver.start(continuation)
            }
        } onCancel: {
            driver.cancel()
        }
    }

    /// Dials a peer direct-first: `lane` at `directAddresses` (skipped when
    /// either is missing) against `main` at `relayAddress`.
    public static func dial(
        lane: IrxEndpointSupervisor?,
        directAddresses: [String],
        main: IrxEndpointSupervisor,
        relayAddress: EndpointAddr,
        credentials: [IrxRelayCredential],
        timing: Timing = .standard
    ) async throws -> Outcome<IrxConnection> {
        var direct: (@Sendable () async throws -> IrxConnection)?
        if let lane, !directAddresses.isEmpty {
            let laneAddress = EndpointAddr(id: relayAddress.id(), relayUrl: nil, addresses: directAddresses)
            direct = { try await lane.dial(address: laneAddress, credentials: []) }
        }
        return try await race(
            timing: timing, direct: direct,
            relay: { try await main.dial(address: relayAddress, credentials: credentials) },
            discard: { close($0, reason: "supermux-dial-race-lost") })
    }

    /// A direct handshake on `lane` that is never admitted: how long it took
    /// to reach the peer at one of `addresses`, or nil when none answered
    /// within `deadline`. The connection is closed right away; the host sees
    /// a connection that never sent its hello and drops it.
    public static func probe(
        lane: IrxEndpointSupervisor,
        peerEndpointIDHex: String,
        addresses: [String],
        deadline: Duration
    ) async -> Duration? {
        guard !addresses.isEmpty,
              let address = try? lane.dialAddress(
                peerEndpointIDHex: peerEndpointIDHex, relayURL: nil, directAddresses: addresses) else { return nil }
        let started = ContinuousClock.now
        let abandoned = IrxAbandonedHandshake()
        let result = try? await withIrxDeadlineResult(deadline) { () -> IrxConnection? in
            let connection = try await lane.dial(address: address, credentials: [])
            guard !abandoned.isSet else {
                close(connection, reason: "supermux-route-probe")
                return nil
            }
            return connection
        }
        guard case .operation(let connection?) = result else {
            abandoned.set()
            return nil
        }
        close(connection, reason: "supermux-route-probe")
        return started.duration(to: .now)
    }

    /// Whether a direct session still answers: the peer's bytes arrived in
    /// the last `quietFor`, or it answers a keepalive within `probeDeadline`.
    /// A lane session has no relay path to fail over to, so its path dying
    /// leaves the session silent until QUIC's 30 s idle timeout; this is the
    /// faster evidence.
    public static func answers(
        _ connection: IrxConnection,
        quietFor: Duration = quietBeforeProbe,
        probeDeadline: Duration = livenessProbeDeadline
    ) async -> Bool {
        if await connection.isConnectionClosed() { return false }
        if let last = connection.inboundActivity.lastActivity, last.duration(to: .now) < quietFor { return true }
        return await connection.probeLiveness(deadline: probeDeadline)
    }

    /// Closes a connection nobody will use, with a reason the host's journal shows.
    static func close(_ connection: IrxConnection, reason: String) {
        try? connection.underlying.close(errorCode: 0, reason: Data(reason.utf8))
    }
}

/// The race's decisions, as a pure state machine: events in, effects out.
struct SupermuxIrxDialRaceState<Value: Sendable> {
    typealias Winner = (value: Value, leg: SupermuxIrxDialLeg)

    enum Event {
        case directSucceeded(Value)
        case directFailed(any Error)
        case headStartElapsed
        case directDeadlineElapsed
        case relaySucceeded(Value)
        case relayFailed(any Error)
        case cancelled
    }

    enum Effect {
        case startRelay
        case cancelDirect
        case cancelRelay
        case discard(Value)
        case finish(Result<Winner, any Error>)
    }

    private enum Direct {
        case absent, pending, failed(timedOut: Bool), succeeded
    }

    private enum Relay {
        case notStarted, pending, held(Value), failed(any Error), done
    }

    private var direct: Direct
    private var relay: Relay = .notStarted
    private(set) var decided = false

    init(hasDirect: Bool) {
        direct = hasDirect ? .pending : .absent
    }

    /// What to do before any event.
    mutating func start() -> [Effect] {
        guard case .absent = direct else { return [] }
        return startRelay()
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .directSucceeded(let value):
            guard !decided, case .pending = direct else { return [.discard(value)] }
            direct = .succeeded
            var effects: [Effect] = []
            switch relay {
            case .pending: effects.append(.cancelRelay)
            case .held(let held): effects.append(.discard(held))
            case .notStarted, .failed, .done: break
            }
            relay = .done
            return effects + finish(.success((value, .direct)))
        case .directFailed:
            guard !decided, case .pending = direct else { return [] }
            direct = .failed(timedOut: false)
            return directGaveUp()
        case .directDeadlineElapsed:
            guard !decided, case .pending = direct else { return [] }
            direct = .failed(timedOut: true)
            return [.cancelDirect] + directGaveUp()
        case .headStartElapsed:
            guard !decided, case .notStarted = relay else { return [] }
            return startRelay()
        case .relaySucceeded(let value):
            guard !decided else { return [.discard(value)] }
            if case .pending = direct {
                relay = .held(value)
                return []
            }
            relay = .done
            return finish(.success((value, .relay)))
        case .relayFailed(let error):
            guard !decided else { return [] }
            relay = .failed(error)
            if case .pending = direct { return [] }
            return finish(.failure(error))
        case .cancelled:
            guard !decided else { return [] }
            var effects: [Effect] = []
            if case .pending = direct { effects.append(.cancelDirect) }
            switch relay {
            case .pending: effects.append(.cancelRelay)
            case .held(let held): effects.append(.discard(held))
            case .notStarted, .failed, .done: break
            }
            relay = .done
            return effects + finish(.failure(CancellationError()))
        }
    }

    private mutating func startRelay() -> [Effect] {
        relay = .pending
        return [.startRelay]
    }

    /// The lane failed or ran out of time: the relay decides.
    private mutating func directGaveUp() -> [Effect] {
        switch relay {
        case .notStarted: return startRelay()
        case .pending: return []
        case .held(let value):
            relay = .done
            return finish(.success((value, .relay)))
        case .failed(let error): return finish(.failure(error))
        case .done: return []
        }
    }

    private mutating func finish(_ result: Result<Winner, any Error>) -> [Effect] {
        decided = true
        return [.finish(result)]
    }
}

/// Runs ``SupermuxIrxDialRaceState``: one task per leg and per timer,
/// effects outside the lock.
private final class SupermuxIrxDialRaceDriver<Value: Sendable>: @unchecked Sendable {
    private let timing: SupermuxIrxDirectFirstDial.Timing
    private let direct: (@Sendable () async throws -> Value)?
    private let relay: @Sendable () async throws -> Value
    private let discard: @Sendable (Value) async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var state: SupermuxIrxDialRaceState<Value>
    private var continuation: CheckedContinuation<SupermuxIrxDirectFirstDial.Outcome<Value>, any Error>?
    private var result: Result<SupermuxIrxDialRaceState<Value>.Winner, any Error>?
    private var tasks: [String: Task<Void, Never>] = [:]
    private let startedAt = ContinuousClock.now
    private var fields: [String: String]

    init(
        timing: SupermuxIrxDirectFirstDial.Timing,
        direct: (@Sendable () async throws -> Value)?,
        relay: @escaping @Sendable () async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.timing = timing
        self.direct = direct
        self.relay = relay
        self.discard = discard
        self.sleep = sleep
        state = SupermuxIrxDialRaceState(hasDirect: direct != nil)
        fields = ["direct": direct == nil ? "none" : "pending", "relay": "not-started"]
    }

    func start(_ continuation: CheckedContinuation<SupermuxIrxDirectFirstDial.Outcome<Value>, any Error>) {
        let effects: [SupermuxIrxDialRaceState<Value>.Effect] = lock.withLock {
            self.continuation = continuation
            // A cancel that came first has already decided the race.
            return state.decided ? [] : state.start()
        }
        if let direct {
            launch("direct") {
                let outcome = await Self.run(direct)
                self.handle(Self.directEvent(outcome), note: ("direct", outcome))
            }
            launch("head-start") { [sleep, timing] in
                guard (try? await sleep(timing.headStart)) != nil else { return }
                self.handle(.headStartElapsed)
            }
            launch("deadline") { [sleep, timing] in
                guard (try? await sleep(timing.directDeadline)) != nil else { return }
                self.handle(.directDeadlineElapsed)
            }
        }
        perform(effects)
        resumeIfFinished()
    }

    func cancel() {
        handle(.cancelled)
    }

    private func handle(
        _ event: SupermuxIrxDialRaceState<Value>.Event,
        note: (leg: String, outcome: Result<Value, any Error>)? = nil
    ) {
        let effects = lock.withLock { () -> [SupermuxIrxDialRaceState<Value>.Effect] in
            if let note, fields[note.leg] == "pending" {
                let milliseconds = Self.milliseconds(startedAt.duration(to: .now))
                switch note.outcome {
                case .success: fields[note.leg] = "ok \(milliseconds)"
                case .failure: fields[note.leg] = "failed \(milliseconds)"
                }
            }
            if case .directDeadlineElapsed = event, fields["direct"] == "pending" { fields["direct"] = "timeout" }
            return state.handle(event)
        }
        perform(effects)
        resumeIfFinished()
    }

    private func perform(_ effects: [SupermuxIrxDialRaceState<Value>.Effect]) {
        for effect in effects {
            switch effect {
            case .startRelay:
                lock.withLock { fields["relay"] = "pending" }
                launch("relay") { [relay] in
                    let outcome = await Self.run(relay)
                    self.handle(Self.relayEvent(outcome), note: ("relay", outcome))
                }
            case .cancelDirect:
                cancelTask("direct")
                cancelTask("deadline")
                cancelTask("head-start")
            case .cancelRelay:
                lock.withLock { if fields["relay"] == "pending" { fields["relay"] = "cancelled" } }
                cancelTask("relay")
            case .discard(let value):
                let discard = discard
                Task { await discard(value) }
            case .finish(let finished):
                lock.withLock {
                    result = finished
                    for leg in ["direct", "relay"] where fields[leg] == "pending" { fields[leg] = "cancelled" }
                }
                cancelTask("head-start")
                cancelTask("deadline")
            }
        }
    }

    private func resumeIfFinished() {
        let ready = lock.withLock { () -> (CheckedContinuation<SupermuxIrxDirectFirstDial.Outcome<Value>, any Error>, Result<SupermuxIrxDialRaceState<Value>.Winner, any Error>, [String: String])? in
            guard let continuation, let result else { return nil }
            self.continuation = nil
            return (continuation, result, fields)
        }
        guard let (continuation, result, fields) = ready else { return }
        switch result {
        case .success(let winner):
            var journal = fields
            journal["winner"] = winner.leg.rawValue
            continuation.resume(returning: .init(value: winner.value, leg: winner.leg, journalFields: journal))
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    /// Starts a leg or timer unless the race is already decided. Each task
    /// holds the driver until it ends, so a leg that finishes after the
    /// caller resumed still has its connection closed.
    private func launch(_ name: String, _ body: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard !state.decided else { return }
            tasks[name] = Task { await body() }
        }
    }

    private func cancelTask(_ name: String) {
        lock.withLock { tasks[name] }?.cancel()
    }

    private static func run(_ leg: @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        do { return .success(try await leg()) } catch { return .failure(error) }
    }

    private static func directEvent(_ outcome: Result<Value, any Error>) -> SupermuxIrxDialRaceState<Value>.Event {
        switch outcome {
        case .success(let value): return .directSucceeded(value)
        case .failure(let error): return .directFailed(error)
        }
    }

    private static func relayEvent(_ outcome: Result<Value, any Error>) -> SupermuxIrxDialRaceState<Value>.Event {
        switch outcome {
        case .success(let value): return .relaySucceeded(value)
        case .failure(let error): return .relayFailed(error)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
// SUPERMUX:end route-direct-lane

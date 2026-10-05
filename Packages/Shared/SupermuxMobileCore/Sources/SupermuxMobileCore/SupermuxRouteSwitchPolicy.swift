import Foundation

/// When a link to one of the user's Macs moves between the direct lane and
/// the relay. Shared by the Mac (its links to other Macs) and the phone (its
/// sessions to each Mac).
///
/// A dial races the direct lane (the other Mac's LAN and Tailscale addresses
/// on a relay-less endpoint) against the relay, direct first. This decides
/// what happens after: a link on the relay tries a direct handshake now and
/// then and, when one answers, redials once to land direct (``Action/upgrade``);
/// a direct session with no relay path beside it that stops answering redials
/// at once to land on the relay (``Action/fallBack``). A path that flaps is
/// kept off direct for longer each time, so reconnects stay bounded.
///
/// Pure state, one per link: the owner feeds it the live session's path about
/// once a second and the answers to the probes and checks it asked for, and
/// acts on what it returns. The redials themselves go through the owner's own
/// reconnect policy (on the Mac, the link's: a fall back from a session that
/// proved nothing still waits its backoff).
///
/// ```swift
/// policy.sessionStarted(at: now)
/// switch policy.observe(.relay, at: now) {
/// case .probe: probeDirect()       // then policy.probeFinished(session:succeeded:at:)
/// case .upgrade, .fallBack: break  // only from the answers
/// default: break
/// }
/// ```
public struct SupermuxRouteSwitchPolicy: Equatable, Sendable {
    /// The path a link's live session uses, as its connection reports it.
    public enum Path: Equatable, Sendable {
        case relay
        /// A direct path. `backedUp`: a relay path stays open beside it (iroh
        /// moved a relayed session itself), so iroh fails it over on its own.
        case direct(backedUp: Bool)
    }

    /// What the owner does now.
    public enum Action: Equatable, Sendable {
        case none
        /// Try a direct handshake on the lane (never admitted), then report it
        /// with ``SupermuxRouteSwitchPolicy/probeFinished(session:succeeded:at:jitter:)``.
        case probe
        /// Check the direct session still answers, then report it with
        /// ``SupermuxRouteSwitchPolicy/livenessChecked(session:answered:at:)``.
        case checkLiveness
        /// Redial once; the race lands on direct.
        case upgrade
        /// The direct session stopped answering: redial; the race skips direct.
        case fallBack
    }

    /// How long a relayed link waits between direct handshakes.
    public static let probeInterval: TimeInterval = 10
    /// The wait once direct has failed ``failuresBeforeSlowProbing`` times in a row.
    public static let slowProbeInterval: TimeInterval = 30
    public static let failuresBeforeSlowProbing = 5
    /// Moves to direct are at least this far apart.
    public static let minimumUpgradeInterval: TimeInterval = 30
    /// Consecutive unanswered liveness checks before a direct session falls back.
    public static let missesBeforeFallBack = 2
    /// How long direct is not tried after the first flap; each further flap doubles it.
    public static let holdOffBase: TimeInterval = 30
    public static let holdOffCap: TimeInterval = 600
    /// A direct session up this long proves the path; the flap count starts over.
    public static let stableDirectLifetime: TimeInterval = 120
    /// Probe waits are spread by up to this fraction either way, so links do not probe in step.
    public static let jitterFraction = 0.2

    /// The live session's number (each start bumps it); answers carry it so
    /// an answer about an ended session is ignored.
    public private(set) var session = 0
    /// Consecutive direct handshakes that failed.
    public private(set) var probeFailures = 0
    /// Consecutive flaps: direct sessions that fell back, or moves that landed on the relay.
    public private(set) var flaps = 0
    /// Direct is not used (no probe, no direct leg in a dial) before this.
    public private(set) var holdOffUntil: Date?

    private var startedAt: Date?
    private var path: Path?
    private var nextProbeAt: Date?
    private var probing = false
    private var checking = false
    private var misses = 0
    private var lastUpgradeAt: Date?
    private var upgradePending = false

    public init() {}

    /// The link connected; `jitter` (0…1) spreads the first probe's wait.
    public mutating func sessionStarted(at now: Date, jitter: Double = 0.5) {
        session &+= 1
        startedAt = now
        path = nil
        probing = false
        checking = false
        misses = 0
        nextProbeAt = now.addingTimeInterval(Self.interval(Self.probeInterval, jitter: jitter))
    }

    /// The link's session ended.
    public mutating func sessionEnded() {
        startedAt = nil
        path = nil
        probing = false
        checking = false
        misses = 0
    }

    /// Whether a dial may use the direct lane now.
    public func allowsDirect(at now: Date) -> Bool {
        holdOffUntil.map { now >= $0 } ?? true
    }

    // Red stubs (review findings T4, T5, T7, T8, T13, H3): not implemented yet.
    public static let recoveryWindow: TimeInterval = 30
    public static let lostRacesBeforeNoHold = 2
    public private(set) var lostRaces = 0
    public var holdsRelayInRace: Bool { true }
    public mutating func networkChanged(at now: Date) { probeSoon(at: now) }
    public mutating func upgradeStarted(at now: Date) {}
    public mutating func directAdmissionFailed() {}
    public mutating func dialUsesDirect(at now: Date) -> Bool { allowsDirect(at: now) }
    public mutating func raceFinished(directWon: Bool) {}
    public mutating func candidatesChanged(at now: Date) {}
    public mutating func observe(_ path: Path, hasCandidates: Bool, at now: Date) -> Action { observe(path, at: now) }

    /// The live session's path, sampled about once a second.
    public mutating func observe(_ path: Path, at now: Date) -> Action {
        guard let startedAt else { return .none }
        self.path = path
        switch path {
        case .relay:
            if upgradePending {
                // The move's redial landed on the relay: the probe answered, the race did not.
                upgradePending = false
                recordFlap(at: now)
            }
            guard !probing, allowsDirect(at: now), let due = nextProbeAt, now >= due else { return .none }
            probing = true
            return .probe
        case .direct(let backedUp):
            upgradePending = false
            if now.timeIntervalSince(startedAt) >= Self.stableDirectLifetime { flaps = 0 }
            guard !backedUp else {
                misses = 0
                return .none
            }
            guard !checking else { return .none }
            checking = true
            return .checkLiveness
        }
    }

    /// The answer to a ``Action/probe`` started during `session`.
    public mutating func probeFinished(session: Int, succeeded: Bool, at now: Date, jitter: Double = 0.5) -> Action {
        guard session == self.session, startedAt != nil, probing else { return .none }
        probing = false
        if succeeded {
            probeFailures = 0
            let spaced = lastUpgradeAt.map { now.timeIntervalSince($0) >= Self.minimumUpgradeInterval } ?? true
            if path == .relay, allowsDirect(at: now), spaced {
                lastUpgradeAt = now
                upgradePending = true
                return .upgrade
            }
        } else {
            probeFailures += 1
        }
        let base = probeFailures >= Self.failuresBeforeSlowProbing ? Self.slowProbeInterval : Self.probeInterval
        nextProbeAt = now.addingTimeInterval(Self.interval(base, jitter: jitter))
        return .none
    }

    /// The answer to a ``Action/checkLiveness`` started during `session`.
    public mutating func livenessChecked(session: Int, answered: Bool, at now: Date) -> Action {
        guard session == self.session, startedAt != nil, checking else { return .none }
        checking = false
        guard !answered else {
            misses = 0
            return .none
        }
        misses += 1
        guard misses >= Self.missesBeforeFallBack else { return .none }
        misses = 0
        recordFlap(at: now)
        return .fallBack
    }

    /// Wake or a network change: probe a relayed link at its next sample
    /// instead of waiting out the cadence. The wait after a flap still holds.
    public mutating func probeSoon(at now: Date) {
        guard startedAt != nil else { return }
        probeFailures = 0
        nextProbeAt = now
    }

    /// How long direct is not tried after `flaps` consecutive flaps.
    public static func holdOff(afterFlaps flaps: Int) -> TimeInterval {
        // 2^5 × 30 s already passes the cap; the bound keeps a long streak from overflowing.
        let doublings = min(max(flaps - 1, 0), 6)
        return min(holdOffBase * Double(1 << doublings), holdOffCap)
    }

    /// `base` spread by `jitter`, a draw in 0…1 (0 is 20 % shorter, 1 is 20 % longer), to the millisecond.
    public static func interval(_ base: TimeInterval, jitter: Double) -> TimeInterval {
        let factor = 1 + jitterFraction * (2 * min(max(jitter, 0), 1) - 1)
        return (base * factor * 1_000).rounded() / 1_000
    }

    private mutating func recordFlap(at now: Date) {
        flaps += 1
        holdOffUntil = now.addingTimeInterval(Self.holdOff(afterFlaps: flaps))
    }
}

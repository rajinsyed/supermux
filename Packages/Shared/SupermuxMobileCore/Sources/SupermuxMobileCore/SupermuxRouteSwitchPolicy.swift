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
/// kept off direct for longer each time (30 s, doubling to 10 min; two
/// minutes direct starts it over), so reconnects stay bounded.
///
/// A wake or a real network change (``networkChanged(at:)``) gives direct a
/// fresh chance: the hold-off and the flap count clear, a relayed session
/// probes at its next sample (a session that starts within
/// ``recoveryWindow`` too), and the first fall back within that window is
/// not a flap, since the old path dying is the change itself.
///
/// Pure state, one per link: the owner feeds it the live session's path about
/// once a second and the answers to the probes and checks it asked for, and
/// acts on what it returns. The redials themselves go through the owner's own
/// reconnect policy (on the Mac, the link's: a fall back from a session that
/// proved nothing still waits its backoff).
///
/// ```swift
/// policy.sessionStarted(at: now)
/// switch policy.observe(.relay, hasCandidates: true, at: now) {
/// case .probe: probeDirect()       // then policy.probeFinished(session:succeeded:at:)
/// case .checkLiveness: check()     // then policy.livenessChecked(session:answered:at:)
/// default: break
/// }
/// // A probe that answered returns .upgrade: redial, then policy.upgradeStarted(at:).
/// // Before each dial: policy.dialUsesDirect(at:) and policy.holdsRelayInRace;
/// // after a race that tried direct: policy.raceFinished(directWon:).
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
        /// Redial once; the race lands on direct. Report the redial with
        /// ``SupermuxRouteSwitchPolicy/upgradeStarted(at:)`` once it happened.
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
    /// After a wake or network change: a session starting this soon probes at
    /// its first sample, and the first fall back this soon is not a flap.
    public static let recoveryWindow: TimeInterval = 30
    /// Races in a row that direct lost on this network before a dial stops
    /// holding a ready relay connection for direct (see ``holdsRelayInRace``).
    public static let lostRacesBeforeNoHold = 2

    /// The live session's number (each start bumps it); answers carry it so
    /// an answer about an ended session is ignored.
    public private(set) var session = 0
    /// Consecutive direct handshakes that failed.
    public private(set) var probeFailures = 0
    /// Consecutive flaps: direct sessions that fell back, or moves that landed on the relay.
    public private(set) var flaps = 0
    /// Direct is not used (no probe, no direct leg in a dial) before this.
    public private(set) var holdOffUntil: Date?
    /// Races in a row, since the last network change, whose direct leg lost.
    public private(set) var lostRaces = 0

    private var startedAt: Date?
    private var path: Path?
    private var nextProbeAt: Date?
    private var probing = false
    private var checking = false
    private var misses = 0
    private var lastUpgradeAt: Date?
    private var upgradePending = false
    /// A session starting before this probes at its first sample (a recovery came while none was live).
    private var probeSoonUntil: Date?
    /// A fall back before this is not a flap (once): the network just changed.
    private var flapGraceUntil: Date?
    private var skipsDirectOnce = false

    public init() {}

    // MARK: - Sessions

    /// The link connected; `jitter` (0…1) spreads the first probe's wait.
    /// Within ``recoveryWindow`` of a wake or network change it probes at
    /// its first sample instead.
    public mutating func sessionStarted(at now: Date, jitter: Double = 0.5) {
        session &+= 1
        startedAt = now
        path = nil
        probing = false
        checking = false
        misses = 0
        if let until = probeSoonUntil, now < until {
            nextProbeAt = now
        } else {
            nextProbeAt = now.addingTimeInterval(Self.interval(Self.probeInterval, jitter: jitter))
        }
        probeSoonUntil = nil
    }

    /// The link's session ended.
    public mutating func sessionEnded() {
        startedAt = nil
        path = nil
        probing = false
        checking = false
        misses = 0
    }

    // MARK: - Dials

    /// Whether a dial may use the direct lane now.
    public func allowsDirect(at now: Date) -> Bool {
        holdOffUntil.map { now >= $0 } ?? true
    }

    /// Whether the dial starting now races the direct lane: not while direct
    /// is held off, and not once right after a direct-lane admission failed.
    public mutating func dialUsesDirect(at now: Date) -> Bool {
        if skipsDirectOnce {
            skipsDirectOnce = false
            return false
        }
        return allowsDirect(at: now)
    }

    /// A session dialed on the direct lane failed its admission: the next dial
    /// skips the lane once, so a lane whose handshakes work but whose sessions
    /// do not can never keep the link off the relay.
    public mutating func directAdmissionFailed() {
        skipsDirectOnce = true
    }

    /// Whether the dial's race holds a relay connection that is ready first
    /// until direct's deadline. False after ``lostRacesBeforeNoHold`` lost
    /// races on this network (cellular or a hotel without Tailscale): direct
    /// still gets its head start, but no dial waits 1.5 s for it.
    public var holdsRelayInRace: Bool {
        lostRaces < Self.lostRacesBeforeNoHold
    }

    /// A dial that raced the direct lane finished; whether direct won.
    public mutating func raceFinished(directWon: Bool) {
        lostRaces = directWon ? 0 : lostRaces + 1
    }

    // MARK: - Samples and answers

    /// The live session's path, sampled about once a second. `hasCandidates`:
    /// whether the peer's direct addresses (as this device can reach them)
    /// are known; without any a relayed session is not probed.
    public mutating func observe(_ path: Path, hasCandidates: Bool = true, at now: Date) -> Action {
        guard let startedAt else { return .none }
        self.path = path
        switch path {
        case .relay:
            if upgradePending {
                // The move's redial landed on the relay: the probe answered, the race did not.
                upgradePending = false
                recordFlap(at: now)
            }
            guard hasCandidates, !probing, allowsDirect(at: now), let due = nextProbeAt, now >= due else { return .none }
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
            // Direct works on this network now: the move's race holds the relay for it.
            lostRaces = 0
            let spaced = lastUpgradeAt.map { now.timeIntervalSince($0) >= Self.minimumUpgradeInterval } ?? true
            nextProbeAt = now.addingTimeInterval(Self.interval(Self.probeInterval, jitter: jitter))
            if path == .relay, allowsDirect(at: now), spaced { return .upgrade }
            return .none
        }
        probeFailures += 1
        let base = probeFailures >= Self.failuresBeforeSlowProbing ? Self.slowProbeInterval : Self.probeInterval
        nextProbeAt = now.addingTimeInterval(Self.interval(base, jitter: jitter))
        return .none
    }

    /// The owner redialed for an ``Action/upgrade``. Only a move that happened
    /// spaces the next one and counts as a flap should it land on the relay.
    public mutating func upgradeStarted(at now: Date) {
        lastUpgradeAt = now
        upgradePending = true
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

    // MARK: - Recoveries

    /// This device woke or its network really changed (its interfaces or
    /// addresses): whatever kept direct off may be gone. The hold-off, the
    /// flap count and the lost races clear; a relayed session probes at its
    /// next sample, or the next session within ``recoveryWindow``; and the
    /// first fall back within that window is not a flap.
    public mutating func networkChanged(at now: Date) {
        flaps = 0
        holdOffUntil = nil
        lostRaces = 0
        flapGraceUntil = now.addingTimeInterval(Self.recoveryWindow)
        probeSoon(at: now)
    }

    /// Probe a relayed session at its next sample, or the next session if it
    /// starts within ``recoveryWindow`` (the app came to the foreground). A
    /// hold-off after a flap still holds.
    public mutating func probeSoon(at now: Date) {
        probeFailures = 0
        if startedAt != nil {
            nextProbeAt = now
        } else {
            probeSoonUntil = now.addingTimeInterval(Self.recoveryWindow)
        }
    }

    /// The peer handed over new direct addresses: a relayed session probes at
    /// its next sample.
    public mutating func candidatesChanged(at now: Date) {
        guard startedAt != nil else { return }
        nextProbeAt = now
    }

    // MARK: - Arithmetic

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
        if let until = flapGraceUntil, now < until {
            flapGraceUntil = nil
            return
        }
        flaps += 1
        holdOffUntil = now.addingTimeInterval(Self.holdOff(afterFlaps: flaps))
    }
}

public import Foundation
public import SupermuxMobileCore

/// The phone's route decisions for every Mac it dials: one
/// ``SupermuxRouteSwitchPolicy`` per Mac endpoint (SupermuxMobileCore, the
/// same policy the Mac runs for its links to other Macs), the lane each
/// admitted session went out on, and the network the phone was last on.
///
/// Pure state. The app's Iroh runtime owns one and does the I/O it asks for:
/// - **Dials.** ``dialPlan(for:at:)`` says whether a dial races the direct
///   lane (not while a flap holds direct off, which doubles with each flap,
///   and not once after a lane admission failed) and whether the race holds
///   a relay connection that is ready first. ``raceFinished(for:directWon:)``
///   and ``admissionFailed(for:lane:)`` report back.
/// - **Sessions.** ``sessionAdmitted(for:sessionID:lane:at:jitter:)`` starts
///   following an automatic session. ``observe(_:sessionID:sample:hasCandidates:at:)``,
///   about every 2 s, stops following it once the engine, having had it, no
///   longer does (an admission comes before the engine adopts the session),
///   and says when to probe the direct lane or check that a direct session
///   still answers. A direct-lane session has no relay path, so it is checked even
///   while iroh reports no selected path.
/// - **Network.** ``networkSettled(on:at:)`` tells a real network change
///   (the phone's networks differ: ``SupermuxLocalInterface/networkFingerprint(_:)``)
///   from a foreground or a path update that changed nothing, whatever came
///   and went on the same network (a link-local address, AWDL, an IPsec
///   tunnel, a rotated temporary IPv6 address). Only a real change clears a
///   flap's hold-off; either one probes relayed sessions soon.
public struct SupermuxPhoneRoutePolicies: Sendable {
    /// What the runtime does for one Mac now.
    public enum Step: Equatable, Sendable {
        case none
        /// Try one direct handshake (never admitted), then report it with
        /// ``SupermuxPhoneRoutePolicies/probeFinished(for:session:succeeded:at:jitter:)``.
        case probe(session: Int)
        /// Check that the direct session still answers, then report it with
        /// ``SupermuxPhoneRoutePolicies/livenessChecked(for:session:answered:at:)``.
        case checkLiveness(session: Int)
    }

    /// How a dial to one Mac runs.
    public struct DialPlan: Equatable, Sendable {
        /// Whether the dial races the direct lane.
        public let racesDirect: Bool
        /// Whether the race holds a relay connection that is ready first
        /// until direct's deadline.
        public let holdsRelay: Bool

        public init(racesDirect: Bool, holdsRelay: Bool) {
            self.racesDirect = racesDirect
            self.holdsRelay = holdsRelay
        }
    }

    /// The selected path of a session, as iroh reports it.
    public struct Sample: Equatable, Sendable {
        /// Whether the selected path goes through a relay.
        public let isRelay: Bool
        /// Whether a relay path stays open beside it.
        public let hasRelayPath: Bool

        public init(isRelay: Bool, hasRelayPath: Bool) {
            self.isRelay = isRelay
            self.hasRelayPath = hasRelayPath
        }
    }

    /// How long after a real network change a liveness check pings a quiet
    /// session at once instead of trusting its recent traffic.
    public static let urgentCheckWindow: TimeInterval = 10

    private var policies: [String: SupermuxRouteSwitchPolicy] = [:]
    /// The admitted session each followed Mac's policy is about.
    private var sessions: [String: String] = [:]
    /// Followed Macs whose admitted session the engine has had.
    private var adopted: Set<String> = []
    /// The lane each followed Mac's admitted session went out on.
    public private(set) var lanes: [String: SupermuxDialLane] = [:]
    /// The networks the phone was last judged on.
    private var network: Set<String>?
    private var lastRecoveryAt: Date?

    public init() {}

    /// The Macs whose sessions are followed.
    public var followedMacs: [String] { Array(sessions.keys) }

    /// One Mac's policy (journal fields, tests).
    public func policy(for mac: String) -> SupermuxRouteSwitchPolicy? {
        policies[mac]
    }

    // MARK: - Dials

    /// How the dial to `mac` starting now runs.
    public mutating func dialPlan(for mac: String, at now: Date) -> DialPlan {
        update(mac) { policy in
            DialPlan(racesDirect: policy.dialUsesDirect(at: now), holdsRelay: policy.holdsRelayInRace)
        }
    }

    /// A dial to `mac` that raced the direct lane finished.
    public mutating func raceFinished(for mac: String, directWon: Bool) {
        update(mac) { $0.raceFinished(directWon: directWon) }
    }

    /// A session to `mac` was admitted. `lane` is nil for a session the
    /// automatic dial did not make (the Direct or Tailscale method), which is
    /// not followed.
    public mutating func sessionAdmitted(
        for mac: String, sessionID: String, lane: SupermuxDialLane?, at now: Date, jitter: Double
    ) {
        guard let lane else {
            sessionEnded(mac)
            return
        }
        sessions[mac] = sessionID
        adopted.remove(mac)
        lanes[mac] = lane
        update(mac) { $0.sessionStarted(at: now, jitter: jitter) }
    }

    /// A session to `mac` failed its admission. One dialed on the direct lane
    /// makes the next dial skip the lane once, so a lane whose handshakes work
    /// but whose sessions do not can never keep the Mac off the relay.
    public mutating func admissionFailed(for mac: String, lane: SupermuxDialLane) {
        guard lane == .direct else { return }
        update(mac) { $0.directAdmissionFailed() }
    }

    // MARK: - Ticks

    /// One look at a followed Mac's session.
    /// - Parameters:
    ///   - mac: The Mac's endpoint id.
    ///   - sessionID: The engine's current session, nil when it has none.
    ///   - sample: Its selected path, nil before iroh selected one.
    ///   - hasCandidates: Whether any of the Mac's direct addresses is
    ///     reachable from the phone now (asked only of a relayed session).
    ///   - now: The current time.
    public mutating func observe(
        _ mac: String, sessionID: String?, sample: Sample?, hasCandidates: Bool, at now: Date
    ) -> Step {
        guard let followed = sessions[mac] else { return .none }
        guard let sessionID else {
            // Before the engine adopts the admitted session it has none.
            if adopted.contains(mac) { sessionEnded(mac) }
            return .none
        }
        // A newer session is being admitted; its admission restarts the policy.
        guard sessionID == followed else { return .none }
        adopted.insert(mac)
        guard let path = path(of: mac, sample: sample) else { return .none }
        return update(mac) { policy in
            let number = policy.session
            switch policy.observe(path, hasCandidates: hasCandidates, at: now) {
            case .probe: return .probe(session: number)
            case .checkLiveness: return .checkLiveness(session: number)
            case .none, .upgrade, .fallBack: return .none
            }
        }
    }

    /// The answer to a ``Step/probe(session:)``: ``SupermuxRouteSwitchPolicy/Action/upgrade``
    /// asks for one planned redial, reported with ``upgradeStarted(for:at:)``.
    public mutating func probeFinished(
        for mac: String, session: Int, succeeded: Bool, at now: Date, jitter: Double
    ) -> SupermuxRouteSwitchPolicy.Action {
        policies[mac]?.probeFinished(session: session, succeeded: succeeded, at: now, jitter: jitter) ?? .none
    }

    /// The runtime redialed `mac` for an upgrade.
    public mutating func upgradeStarted(for mac: String, at now: Date) {
        policies[mac]?.upgradeStarted(at: now)
    }

    /// The answer to a ``Step/checkLiveness(session:)``:
    /// ``SupermuxRouteSwitchPolicy/Action/fallBack`` asks for a redial,
    /// which skips the direct lane while the policy holds it off.
    public mutating func livenessChecked(
        for mac: String, session: Int, answered: Bool, at now: Date
    ) -> SupermuxRouteSwitchPolicy.Action {
        policies[mac]?.livenessChecked(session: session, answered: answered, at: now) ?? .none
    }

    /// Whether a liveness check pings a quiet session at once: the network
    /// changed within ``urgentCheckWindow``.
    public func isUrgent(at now: Date) -> Bool {
        lastRecoveryAt.map { now.timeIntervalSince($0) < Self.urgentCheckWindow } ?? false
    }

    // MARK: - Network and addresses

    /// The phone's network settled (after a path update or a foreground) on
    /// `interfaces`. A real change (another network:
    /// ``SupermuxLocalInterface/networkFingerprint(_:)`` differs) gives direct
    /// a fresh chance on every Mac (``SupermuxRouteSwitchPolicy/networkChanged(at:)``:
    /// hold-off, flaps and lost races clear); anything else only probes
    /// relayed sessions soon (``SupermuxRouteSwitchPolicy/probeSoon(at:)``),
    /// and a hold-off holds.
    /// - Returns: Whether the network really changed.
    @discardableResult
    public mutating func networkSettled(on interfaces: [SupermuxLocalInterface], at now: Date) -> Bool {
        let current = SupermuxLocalInterface.networkFingerprint(interfaces)
        let previous = network
        network = current
        guard let previous, previous != current else {
            for mac in Array(policies.keys) { policies[mac]?.probeSoon(at: now) }
            return false
        }
        lastRecoveryAt = now
        for mac in Array(policies.keys) { policies[mac]?.networkChanged(at: now) }
        return true
    }

    /// `mac` handed over new direct addresses: a relayed session probes them now.
    public mutating func candidatesChanged(for mac: String, at now: Date) {
        policies[mac]?.candidatesChanged(at: now)
    }

    /// Forgets every Mac (sign-out); the network snapshot stays.
    public mutating func reset() {
        policies = [:]
        sessions = [:]
        adopted = []
        lanes = [:]
    }

    /// The addresses a dial or a probe tries on the direct lane, at most
    /// ``SupermuxRouteCandidates/limit``, without duplicates:
    /// - the Mac's handed-over and learned ones the phone can reach from its
    ///   interfaces now, best first (``SupermuxRouteCandidates/reachable(_:from:)``:
    ///   never its own addresses; LAN while it is on a private network of
    ///   that family or Tailscale is up, never from cellular alone; Tailscale
    ///   with its tunnel up; global IPv6 with one of its own);
    /// - then the user's Private Addresses less the phone's own
    ///   (``SupermuxRouteCandidates/excludingOwn(_:from:)``): the user named
    ///   them, and they may reach the Mac through a path the phone's
    ///   interfaces do not show.
    ///
    /// Empty means no dial waits for direct.
    public static func directAddresses(
        stored: [String], privateAddresses: [String], interfaces: [SupermuxLocalInterface]
    ) -> [String] {
        let reachable = SupermuxRouteCandidates.reachable(stored, from: interfaces)
        let named = SupermuxRouteCandidates.excludingOwn(privateAddresses, from: interfaces)
        var seen = Set<String>()
        return Array((reachable + named).filter { seen.insert($0).inserted }.prefix(SupermuxRouteCandidates.limit))
    }

    // MARK: - State

    private func path(of mac: String, sample: Sample?) -> SupermuxRouteSwitchPolicy.Path? {
        // A direct-lane session has no relay path, whatever iroh reports now.
        if lanes[mac] == .direct { return .direct(backedUp: false) }
        guard let sample else { return nil }
        return sample.isRelay ? .relay : .direct(backedUp: sample.hasRelayPath)
    }

    private mutating func sessionEnded(_ mac: String) {
        sessions[mac] = nil
        adopted.remove(mac)
        lanes[mac] = nil
        policies[mac]?.sessionEnded()
    }

    /// Runs `body` on `mac`'s policy, made on first use and told of a network
    /// change that came before it.
    private mutating func update<Result>(
        _ mac: String, _ body: (inout SupermuxRouteSwitchPolicy) -> Result
    ) -> Result {
        var policy = policies[mac] ?? newPolicy()
        let result = body(&policy)
        policies[mac] = policy
        return result
    }

    private func newPolicy() -> SupermuxRouteSwitchPolicy {
        var policy = SupermuxRouteSwitchPolicy()
        if let lastRecoveryAt { policy.networkChanged(at: lastRecoveryAt) }
        return policy
    }
}

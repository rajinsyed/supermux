import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// One live session of a remote Mac's link, as the route switcher sees it.
@MainActor
protocol SupermuxRouteSwitchLinkSession: AnyObject, Sendable {
    /// The path it uses now; nil before one is selected.
    var path: SupermuxRouteSwitchPolicy.Path? { get }
    /// Whether any of the peer's direct addresses is reachable from this Mac now.
    func hasDirectAddresses() async -> Bool
    /// A direct handshake on the lane that is never admitted: how long it took, or nil.
    func probeDirect() async -> Duration?
    /// Whether the session still answers. `urgent`: the network just changed,
    /// so a quiet session is probed at once instead of after a keepalive's quiet.
    func answers(urgent: Bool) async -> Bool
}

/// Keeps each remote Mac's link on a direct path whenever one works.
///
/// Once a second, for every connected link, it feeds the live session's path
/// to that link's ``SupermuxRouteSwitchPolicy`` (SupermuxMobileCore, shared
/// with the phone) and does what it says:
/// - on the relay, with a reachable direct address, a direct handshake on the
///   lane every ~10 s; when one answers, one planned redial
///   (`DeviceLink.supermuxPlannedRedial()`), whose race lands on direct;
/// - on a direct path with no relay path beside it (a lane session), a
///   liveness check; two misses report the path lost
///   (`DeviceLink.supermuxReportDirectPathLost()`), and the redial, which skips
///   the lane while the policy holds direct off, lands on the relay.
///
/// Redials go through the link's reconnect policy, so the L1 backoff and
/// liveness rules still govern them. Links that are not connected are never
/// probed. ``probeNow(reason:)`` is the hook for wake and network changes:
/// the policy clears its hold-off and probes now (or at the next session's
/// first sample). The dial asks it whether to race the lane
/// (``dialUsesDirect(_:)``) and whether to hold a ready relay
/// (``holdsRelayInRace(_:)``), and reports how the race went.
///
/// Journals (category `route`): `upgrade {device, probe_ms}`,
/// `upgrade-not-made {device}`, `liveness-miss {device}`,
/// `fallback {device, flaps, hold_off_s}`, `probe-now {reason}`; every probe
/// is `route-probe/probe {device, ok, ms, failures}`, kept out of the link
/// history `cmux iroh-diag` shows (a relayed link probes every 10–30 s).
@MainActor
final class SupermuxDeviceRouteSwitcher {
    /// How often each connected link's path is looked at.
    static let tick: Duration = .seconds(1)
    /// How long a route probe may take.
    static let probeDeadline: Duration = .milliseconds(1500)
    /// How long after a recovery liveness checks probe a quiet session at once.
    static let urgentCheckWindow: TimeInterval = 10

    /// Counters for the DEBUG drivers.
    struct Stats: Equatable {
        var probes = 0
        var probeSuccesses = 0
        var checks = 0
        var misses = 0
        var upgrades = 0
        var fallbacks = 0
    }

    typealias SessionProvider = @MainActor (SupermuxDevice) async -> (any SupermuxRouteSwitchLinkSession)?

    private let devices: SupermuxDevices
    private let journal: IrxJournal
    private let sessionProvider: SessionProvider
    private var policies: [SurfaceDeviceInstanceID: SupermuxRouteSwitchPolicy] = [:]
    private var sessions: [SurfaceDeviceInstanceID: any SupermuxRouteSwitchLinkSession] = [:]
    private var started: Set<SurfaceDeviceInstanceID> = []
    private(set) var stats: [SurfaceDeviceInstanceID: Stats] = [:]
    private var lastRecoveryAt: Date?
    private var loop: Task<Void, Never>?
    private var events: Task<Void, Never>?

    init(devices: SupermuxDevices, journal: IrxJournal, session: @escaping SessionProvider) {
        self.devices = devices
        self.journal = journal
        sessionProvider = session
    }

    /// Starts following links. Idempotent.
    func start() {
        guard loop == nil else { return }
        let stream = devices.events()
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .linkConnected(machine):
                    guard let instance = machine.deviceInstance else { continue }
                    sessionStarted(instance, at: Date())
                case let .linkLost(machine):
                    guard let instance = machine.deviceInstance else { continue }
                    sessions[instance] = nil
                    started.remove(instance)
                    policies[instance]?.sessionEnded()
                case .topic:
                    continue
                }
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let switcher = self else { return }
                await switcher.tickNow()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    // MARK: - The dial's questions

    /// Whether a dial to `instance` races the direct lane now: not while its
    /// policy holds direct off after a flap, and not once right after a
    /// lane admission failed.
    func dialUsesDirect(_ instance: SurfaceDeviceInstanceID) -> Bool {
        policies[instance, default: newPolicy()].dialUsesDirect(at: Date())
    }

    /// Whether a dial to `instance` may use the direct lane now (no hold-off), without using up a skip.
    func allowsDirect(_ instance: SurfaceDeviceInstanceID) -> Bool {
        policies[instance]?.allowsDirect(at: Date()) ?? true
    }

    /// Whether the dial's race waits for direct with a relay connection ready.
    func holdsRelayInRace(_ instance: SurfaceDeviceInstanceID) -> Bool {
        policies[instance]?.holdsRelayInRace ?? true
    }

    /// A dial that raced the lane finished.
    func raceFinished(_ instance: SurfaceDeviceInstanceID, directWon: Bool) {
        policies[instance, default: newPolicy()].raceFinished(directWon: directWon)
    }

    /// A session dialed on the lane failed its admission.
    func directAdmissionFailed(_ instance: SurfaceDeviceInstanceID) {
        policies[instance, default: newPolicy()].directAdmissionFailed()
    }

    /// The peer handed over new direct addresses: a relayed link probes them now.
    func candidatesChanged(_ instance: SurfaceDeviceInstanceID) {
        policies[instance]?.candidatesChanged(at: Date())
    }

    // MARK: - Recoveries

    /// Wake or a network change: every link's policy gives direct a fresh
    /// chance (hold-off cleared, a relayed link probes at its next tick, a
    /// link that is down probes its next session at once). The lane itself
    /// is rebound by the recovery (``SupermuxSystemPower``).
    func probeNow(reason: String) {
        journal.record("route", "probe-now", ["reason": reason])
        let now = Date()
        lastRecoveryAt = now
        for instance in Array(policies.keys) { policies[instance]?.networkChanged(at: now) }
    }

    /// A link's first policy, told of a recovery that came before it.
    private func newPolicy() -> SupermuxRouteSwitchPolicy {
        var policy = SupermuxRouteSwitchPolicy()
        if let lastRecoveryAt { policy.networkChanged(at: lastRecoveryAt) }
        return policy
    }

    /// One pass over the connected links.
    func tickNow() async {
        let now = Date()
        for device in devices.devices where device.isConnected {
            await step(device, now: now)
        }
    }

    // MARK: - One link

    private func sessionStarted(_ instance: SurfaceDeviceInstanceID, at now: Date) {
        sessions[instance] = nil
        started.insert(instance)
        policies[instance, default: newPolicy()].sessionStarted(at: now, jitter: .random(in: 0...1))
    }

    private func step(_ device: SupermuxDevice, now: Date) async {
        let instance = device.instance
        // A link already up when the switcher started has had no connect event.
        if !started.contains(instance) { sessionStarted(instance, at: now) }
        guard let session = await session(for: device), let path = session.path, policies[instance] != nil else { return }
        let hasCandidates = path == .relay ? await session.hasDirectAddresses() : true
        guard var policy = policies[instance] else { return }
        let number = policy.session
        let action = policy.observe(path, hasCandidates: hasCandidates, at: now)
        policies[instance] = policy
        switch action {
        case .probe:
            Task { await probe(device, session: session, number: number) }
        case .checkLiveness:
            Task { await check(device, session: session, number: number) }
        case .none, .upgrade, .fallBack:
            break
        }
    }

    private func session(for device: SupermuxDevice) async -> (any SupermuxRouteSwitchLinkSession)? {
        let instance = device.instance
        if let cached = sessions[instance] { return cached }
        let number = policies[instance]?.session
        // A reconnect while the session was looked up may have handed back the old one.
        guard let made = await sessionProvider(device), started.contains(instance),
              policies[instance]?.session == number else { return nil }
        sessions[instance] = made
        return made
    }

    private func probe(_ device: SupermuxDevice, session: any SupermuxRouteSwitchLinkSession, number: Int) async {
        let instance = device.instance
        let took = await session.probeDirect()
        stats[instance, default: Stats()].probes += 1
        if took != nil { stats[instance, default: Stats()].probeSuccesses += 1 }
        guard var policy = policies[instance] else { return }
        let action = policy.probeFinished(session: number, succeeded: took != nil, at: Date(), jitter: .random(in: 0...1))
        policies[instance] = policy
        var fields = attributes(instance)
        fields["ok"] = took == nil ? "false" : "true"
        fields["ms"] = took.map { String(Self.milliseconds($0)) }
        fields["failures"] = String(policy.probeFailures)
        journal.record("route-probe", "probe", fields)
        guard action == .upgrade, let link = devices.provider(for: device.machine)?.link else { return }
        guard link.supermuxPlannedRedial() else {
            // A directory precondition kept the link where it is: no move, no flap.
            journal.record("route", "upgrade-not-made", attributes(instance))
            return
        }
        policies[instance]?.upgradeStarted(at: Date())
        stats[instance, default: Stats()].upgrades += 1
        var upgrade = attributes(instance)
        upgrade["probe_ms"] = took.map { String(Self.milliseconds($0)) }
        journal.record("route", "upgrade", upgrade)
    }

    private func check(_ device: SupermuxDevice, session: any SupermuxRouteSwitchLinkSession, number: Int) async {
        let instance = device.instance
        let urgent = lastRecoveryAt.map { Date().timeIntervalSince($0) < Self.urgentCheckWindow } ?? false
        let answered = await session.answers(urgent: urgent)
        stats[instance, default: Stats()].checks += 1
        guard var policy = policies[instance] else { return }
        let action = policy.livenessChecked(session: number, answered: answered, at: Date())
        policies[instance] = policy
        guard !answered else { return }
        stats[instance, default: Stats()].misses += 1
        journal.record("route", "liveness-miss", attributes(instance))
        guard action == .fallBack, let link = devices.provider(for: device.machine)?.link else { return }
        stats[instance, default: Stats()].fallbacks += 1
        var fields = attributes(instance)
        fields["flaps"] = String(policy.flaps)
        fields["hold_off_s"] = policy.holdOffUntil.map { String(Int($0.timeIntervalSinceNow.rounded())) }
        journal.record("route", "fallback", fields)
        link.supermuxReportDirectPathLost()
    }

    private func attributes(_ instance: SurfaceDeviceInstanceID) -> [String: String] {
        ["device": String(instance.deviceID.prefix(8)), "tag": instance.tag]
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    // MARK: - DEBUG drivers

    /// The link's policy, for the DEBUG drivers.
    func policy(for instance: SurfaceDeviceInstanceID) -> SupermuxRouteSwitchPolicy? {
        policies[instance]
    }

    /// Forgets a link's policy, cached session and counters (DEBUG drivers);
    /// a connected link starts over at the next tick.
    func reset(_ instance: SurfaceDeviceInstanceID) {
        policies[instance] = nil
        sessions[instance] = nil
        started.remove(instance)
        stats[instance] = nil
    }
}

// MARK: - Live sessions

extension SupermuxDeviceRouteSwitcher {
    /// The live session of `device`'s link: its outgoing Iroh session, or for
    /// the DEBUG loopback device the simulated one when a test turned it on.
    /// Nil in relay-only mode, with the kill switch off, and for the loopback
    /// device otherwise (it has no Iroh session).
    static func liveSession(for device: SupermuxDevice) async -> (any SupermuxRouteSwitchLinkSession)? {
        #if DEBUG
        if device.isLoopback { return await SupermuxRouteSwitchSimulation.shared.session(for: device) }
        #endif
        guard !device.isLoopback, MobileHostIrxRuntime.pathMode == .automatic, SupermuxRouteDialCandidates.isEnabled,
              let connection = await SupermuxDeviceRouteMonitor.outgoingConnection(to: device.instance) else { return nil }
        let key = SupermuxRoutePeerKey(
            deviceID: device.instance.deviceID, tag: device.instance.tag, endpointID: connection.remoteEndpointIDHex)
        return SupermuxIrxRouteSwitchSession(connection: connection, key: key)
    }
}

/// A link's outgoing Iroh session.
@MainActor
final class SupermuxIrxRouteSwitchSession: SupermuxRouteSwitchLinkSession {
    private let connection: IrxConnection
    private let key: SupermuxRoutePeerKey

    init(connection: IrxConnection, key: SupermuxRoutePeerKey) {
        self.connection = connection
        self.key = key
    }

    var path: SupermuxRouteSwitchPolicy.Path? {
        connection.supermuxSelectedPathSample().map { $0.isRelay ? .relay : .direct(backedUp: $0.hasRelayPath) }
    }

    func hasDirectAddresses() async -> Bool {
        await !SupermuxRouteDialCandidates.reachable(for: key).addresses.isEmpty
    }

    func probeDirect() async -> Duration? {
        let addresses = await SupermuxRouteDialCandidates.reachable(for: key).addresses
        let lane = SupermuxComposition.directLane
        guard !addresses.isEmpty, let main = MobileHostIrxRuntime.shared.endpointSupervisor else { return nil }
        // Made here when no dial has used the lane yet (the first dial had no address).
        let supervisor = await lane.beginUse(matching: main)
        let took = await SupermuxIrxDirectFirstDial.probe(
            lane: supervisor, peerEndpointIDHex: connection.remoteEndpointIDHex,
            addresses: addresses, deadline: SupermuxDeviceRouteSwitcher.probeDeadline)
        await lane.endUse()
        return took
    }

    func answers(urgent: Bool) async -> Bool {
        await SupermuxIrxDirectFirstDial.answers(connection, quietFor: urgent ? .zero : SupermuxIrxDirectFirstDial.quietBeforeProbe)
    }
}

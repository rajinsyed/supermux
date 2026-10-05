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
    /// A direct handshake on the lane that is never admitted: how long it took, or nil.
    func probeDirect() async -> Duration?
    /// Whether the session still answers.
    func answers() async -> Bool
}

/// Keeps each remote Mac's link on a direct path whenever one works.
///
/// Once a second, for every connected link, it feeds the live session's path
/// to that link's ``SupermuxRouteSwitchPolicy`` and does what it says:
/// - on the relay, a direct handshake on the lane every ~10 s; when one
///   answers, one planned redial (`DeviceLink.supermuxPlannedRedial()`), whose
///   race lands on direct;
/// - on a direct path with no relay path beside it (a lane session), a
///   liveness check; two misses report the path lost
///   (`DeviceLink.supermuxReportDirectPathLost()`), and the redial, which skips
///   the lane while the policy holds direct off, lands on the relay.
///
/// Redials go through the link's reconnect policy, so the L1 backoff and
/// liveness rules still govern them. Links that are not connected are never
/// probed. ``probeNow(reason:)`` is the hook for wake and network changes.
///
/// Journals (category `route`): `probe {device, ok, ms, failures}`,
/// `upgrade {device, probe_ms}`, `liveness-miss {device}`,
/// `fallback {device, flaps, hold_off_s}`, `probe-now {reason}`.
@MainActor
final class SupermuxDeviceRouteSwitcher {
    /// How often each connected link's path is looked at.
    static let tick: Duration = .seconds(1)
    /// How long a route probe may take.
    static let probeDeadline: Duration = .milliseconds(1500)

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

    /// Whether a dial to `instance` may use the direct lane now (false while
    /// its policy holds direct off after a flap).
    func allowsDirect(_ instance: SurfaceDeviceInstanceID) -> Bool {
        policies[instance]?.allowsDirect(at: Date()) ?? true
    }

    /// Wake or a network change: every relayed link probes direct at its
    /// next tick, and the lane is rebound when no session uses it.
    func probeNow(reason: String) {
        journal.record("route", "probe-now", ["reason": reason])
        let now = Date()
        for instance in Array(policies.keys) { policies[instance]?.probeSoon(at: now) }
        Task { await SupermuxComposition.directLane.rebuildIfIdle(reason: reason) }
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
        policies[instance, default: SupermuxRouteSwitchPolicy()].sessionStarted(at: now, jitter: .random(in: 0...1))
    }

    private func step(_ device: SupermuxDevice, now: Date) async {
        let instance = device.instance
        // A link already up when the switcher started has had no connect event.
        if !started.contains(instance) { sessionStarted(instance, at: now) }
        guard let session = await session(for: device), let path = session.path,
              var policy = policies[instance] else { return }
        let number = policy.session
        let action = policy.observe(path, at: now)
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
        journal.record("route", "probe", fields)
        guard action == .upgrade, let link = devices.provider(for: device.machine)?.link else { return }
        stats[instance, default: Stats()].upgrades += 1
        var upgrade = attributes(instance)
        upgrade["probe_ms"] = took.map { String(Self.milliseconds($0)) }
        journal.record("route", "upgrade", upgrade)
        link.supermuxPlannedRedial()
    }

    private func check(_ device: SupermuxDevice, session: any SupermuxRouteSwitchLinkSession, number: Int) async {
        let instance = device.instance
        let answered = await session.answers()
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

    func probeDirect() async -> Duration? {
        guard let lane = await SupermuxComposition.directLane.current() else { return nil }
        let addresses = await SupermuxComposition.routeCandidateStore.dialAddresses(for: key)
        return await SupermuxIrxDirectFirstDial.probe(
            lane: lane, peerEndpointIDHex: connection.remoteEndpointIDHex,
            addresses: addresses, deadline: SupermuxDeviceRouteSwitcher.probeDeadline)
    }

    func answers() async -> Bool {
        await SupermuxIrxDirectFirstDial.answers(connection)
    }
}

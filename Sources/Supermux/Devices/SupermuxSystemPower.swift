import AppKit
import CmuxIrxTransport
import CmuxMobileHost
import CoreGraphics
import Foundation
import SupermuxKit

/// This Mac's own sleep, wake and network changes, for its links to other
/// Macs and its iroh endpoints (``SupermuxWakePolicy`` decides).
///
/// - **willSleep**: tells the Macs viewing this one it is going to sleep
///   (``SupermuxDeviceSleepCourtesy``), takes each connected link down at once
///   with a planned redial, and the Mac turns dark.
/// - **Dark** (until a full wake): no link dials (``waitUntilAwake()``, the
///   gate in `DeviceLink`'s connect). macOS posts no wake notification for a
///   DarkWake, when a lid-closed laptop runs for 2–35 s; links made then were
///   zombies. Should a wake notification be lost, a display found awake twice
///   in a row ends the dark state.
/// - **A full wake** (didWake or the screens waking) recovers once: after a
///   sleep of 60 s or more the main endpoint is closed and bound again (every
///   QUIC session on it is dead by then; phones and Macs redial, see
///   ``rebuildMainEndpoint()``; expired relay credentials are refreshed
///   first, and without fresh ones the rebuild waits for the next network
///   change within 30 s), iroh is told the network changed, the route
///   switcher gives direct a fresh chance (hold-off cleared, probes now), the
///   idle direct lane is rebound, and links waiting in a backoff dial at
///   once. Dials wait for the rebuild, at most 5 s.
/// - **A network change** (interfaces or IPv4 addresses, Tailscale's `utun`
///   too, debounced 1 s) recovers the same way while awake, without the
///   rebuild (unless one was put off at the wake) or the redials.
///
/// The sleep is measured on the wall clock. Journals (category `power`):
/// `will-sleep {links}`, `recovered {reason, slept_s, main, lane_rebuilt,
/// redialed}`, `dark-ended {reason}`.
@MainActor
final class SupermuxSystemPower {
    /// How long a network change waits for the burst it belongs to.
    static let networkDebounce: Duration = .seconds(1)
    /// How often a dark Mac checks its display (a lost wake notification).
    static let displayCheckInterval: Duration = .seconds(15)
    /// How long dials may wait for the main endpoint's rebuild.
    static let rebuildWaitLimit: Duration = .seconds(5)

    /// What the last recovery did, for the DEBUG drivers.
    struct RecoveryRecord {
        let recovery: SupermuxWakePolicy.Recovery
        /// `rebuilt`, `rebuilt-after-refresh`, `no-endpoint`,
        /// `kept-expired-credentials` or `kept` (no rebuild planned).
        let main: String
        let laneRebuilt: Bool
        let redialed: Int
    }

    private let journal: IrxJournal
    private var policy = SupermuxWakePolicy()
    private var rebuilding = false
    /// The rebuild `rebuilding` belongs to; an older one finishing never clears a newer one's.
    private var rebuildToken: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: MobileHostNetworkPathMonitor?
    private var sawFirstPath = false
    private var networkTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private(set) var lastRecovery: RecoveryRecord?
    private(set) var recoveries = 0

    init(journal: IrxJournal) {
        self.journal = journal
    }

    var isDark: Bool { policy.isDark }

    /// Observes the system's sleep, wake and network path. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let signals: [(Notification.Name, @MainActor @Sendable (SupermuxSystemPower) -> Void)] = [
            (NSWorkspace.willSleepNotification, { $0.willSleep() }),
            (NSWorkspace.didWakeNotification, { $0.woke(.wake) }),
            (NSWorkspace.screensDidWakeNotification, { $0.woke(.screensWake) }),
        ]
        observers = signals.map { name, action in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            }
        }
        let monitor = MobileHostNetworkPathMonitor { [weak self] in self?.pathChanged() }
        monitor.start(queue: DispatchQueue(label: "dev.supermux.power.path", qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - Signals

    /// The Mac is going to sleep. `announce`: tell the Macs viewing this one
    /// (DEBUG drivers leave it out so the loopback link does not hear itself);
    /// `checksDisplay`: watch for a lost wake notification (off for DEBUG
    /// drivers, whose display is awake).
    func willSleep(at now: Date = Date(), announce: Bool = true, checksDisplay: Bool = true) {
        if announce { SupermuxComposition.sleepCourtesy.announce() }
        policy.willSleep(at: now)
        var parked = 0
        for link in SupermuxComposition.devices.links where link.isConnected {
            // Closed now; the redial waits in `waitUntilAwake()` until a full wake.
            link.supermuxPlannedRedial()
            parked += 1
        }
        journal.record("power", "will-sleep", ["links": String(parked)])
        displayTask?.cancel()
        displayTask = checksDisplay ? Task { [weak self] in await self?.watchDisplay() } : nil
    }

    /// A wake signal at `now` (DEBUG drivers may set it to fake a sleep's
    /// length). Returns the recovery it started, if any.
    @discardableResult
    func woke(_ reason: SupermuxWakePolicy.Reason, at now: Date = Date()) -> Task<Void, Never>? {
        guard let recovery = policy.woke(reason, at: now) else { return nil }
        displayTask?.cancel()
        displayTask = nil
        let token = recovery.rebuildsMainEndpoint ? beginRebuild() : nil
        return Task { await recover(recovery, rebuild: token, redialsWaitingLinks: true) }
    }

    /// The network path changed; recovers after the burst settles. Returns
    /// the debounce, which a later change cancels.
    @discardableResult
    func networkChanged() -> Task<Void, Never> {
        networkTask?.cancel()
        let task = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.networkDebounce)) != nil, let self else { return }
            guard let recovery = policy.networkChanged(at: Date()) else { return }
            let token = recovery.rebuildsMainEndpoint ? beginRebuild() : nil
            await recover(recovery, rebuild: token, redialsWaitingLinks: false)
        }
        networkTask = task
        return task
    }

    private func pathChanged() {
        // The first observation is the path the endpoints bound on.
        guard sawFirstPath else { sawFirstPath = true; return }
        networkChanged()
    }

    // MARK: - The dark gate

    /// Returns once this Mac is fully awake and any main-endpoint rebuild is
    /// done; false if the caller was cancelled first. A link's connect waits
    /// here, so nothing dials out of a DarkWake.
    static func waitUntilAwake() async -> Bool {
        let power = SupermuxComposition.systemPower
        while power.policy.isDark || power.rebuilding {
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return false }
        }
        return !Task.isCancelled
    }

    /// While dark: a display awake on two checks in a row means the wake
    /// notification was lost (a DarkWake never lights a display).
    private func watchDisplay() async {
        var awakeChecks = 0
        while policy.isDark {
            guard (try? await Task.sleep(for: Self.displayCheckInterval)) != nil else { return }
            awakeChecks = Self.displayIsAwake() ? awakeChecks + 1 : 0
            if awakeChecks >= 2 {
                journal.record("power", "dark-ended", ["reason": SupermuxWakePolicy.Reason.displayAwake.rawValue])
                woke(.displayAwake)
                return
            }
        }
    }

    private static func displayIsAwake() -> Bool {
        guard !NSScreen.screens.isEmpty else { return false }
        return CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    // MARK: - Recovery

    private func recover(_ recovery: SupermuxWakePolicy.Recovery, rebuild token: UInt64?, redialsWaitingLinks: Bool) async {
        var main = "kept"
        if let token {
            // Dials wait for the new endpoint, but never longer than the limit.
            let limit = Task { [weak self] in
                guard (try? await Task.sleep(for: Self.rebuildWaitLimit)) != nil else { return }
                self?.endRebuild(token)
            }
            let outcome = await Self.rebuildMainEndpoint()
            limit.cancel()
            endRebuild(token)
            if outcome == .keptExpiredCredentials { policy.rebuildPostponed(at: Date()) }
            main = outcome.rawValue
        }
        await MobileHostIrxRuntime.shared.endpointSupervisor?.notifyNetworkChange()
        SupermuxComposition.routeSwitcher.probeNow(reason: recovery.reason.rawValue)
        let laneRebuilt = await SupermuxComposition.directLane.rebuildIfIdle(reason: recovery.reason.rawValue)
        let redialed = redialsWaitingLinks ? redialWaitingLinks() : 0
        recoveries += 1
        lastRecovery = RecoveryRecord(recovery: recovery, main: main, laneRebuilt: laneRebuilt, redialed: redialed)
        journal.record("power", "recovered", [
            "reason": recovery.reason.rawValue,
            "slept_s": recovery.sleptSeconds.map(String.init) ?? "-",
            "main": main,
            "lane_rebuilt": String(laneRebuilt),
            "redialed": String(redialed),
        ])
    }

    private func beginRebuild() -> UInt64 {
        rebuildToken &+= 1
        rebuilding = true
        return rebuildToken
    }

    private func endRebuild(_ token: UInt64) {
        if rebuildToken == token { rebuilding = false }
    }

    /// Closes the main endpoint and binds a new one
    /// (``SupermuxMainEndpointRebuild``): at once with a usable relay
    /// credential; after refreshing expired ones (credentials last 30 min, so
    /// after a night they always have) within the dials' wait limit; or not
    /// at all without one (a relay endpoint cannot bind without it).
    ///
    /// After a sleep of a minute or more every session on it is dead: peers
    /// dropped theirs after 30 s of idle on their own clocks, while this
    /// Mac's stood still. Closing ends them here too (the registry's sessions
    /// and the legacy dialect's; phones and Macs redial on their own), the
    /// accept loop's exit binds the next generation on the same port, and
    /// `foreground()` asks for it at once. The stale relay socket and iroh's
    /// per-peer path blocks go with it. The direct lane is separate.
    private static func rebuildMainEndpoint() async -> SupermuxMainEndpointRebuild.Outcome {
        let runtime = MobileHostIrxRuntime.shared
        let steps = SupermuxMainEndpointRebuild.Steps(
            hasEndpoint: { @MainActor in await runtime.endpointSupervisor?.boundPort() != nil },
            credentialsUsable: { @MainActor in await usableCredentials(runtime) },
            refreshCredentials: { @MainActor in
                guard let control = runtime.controlService else { throw IrxEndpointError.noUsableRelayCredential }
                _ = try await control.refreshRelayCredentials()
            },
            rebuild: { @MainActor in
                await runtime.endpointSupervisor?.close()
                await runtime.foreground()
            })
        return await SupermuxMainEndpointRebuild.run(steps, limit: rebuildWaitLimit)
    }

    /// Whether the main endpoint could bind now: a relay credential that has
    /// not expired (the control plane's own cache holds a refresh before the
    /// runtime applies it), or no relay at all.
    private static func usableCredentials(_ runtime: MobileHostIrxRuntime) async -> Bool {
        guard MobileHostIrxRuntime.pathMode != .directOnly else { return true }
        let now = Int(Date().timeIntervalSince1970)
        if runtime.cachedState?.relayCredentials.contains(where: { $0.expiresAt > now }) == true { return true }
        guard let control = runtime.controlService else { return false }
        return await control.snapshot().cache.relayCredentials.contains { $0.expiresAt > now }
    }

    /// Links waiting in a backoff dial at once: their sessions died with the sleep.
    private func redialWaitingLinks() -> Int {
        var redialed = 0
        for link in SupermuxComposition.devices.links {
            guard case .waiting = link.phase else { continue }
            link.refresh()
            redialed += 1
        }
        return redialed
    }

    // MARK: - DEBUG drivers

    /// Back to awake with no history (DEBUG drivers).
    func reset() {
        policy = SupermuxWakePolicy()
        rebuildToken &+= 1
        rebuilding = false
        displayTask?.cancel()
        displayTask = nil
        lastRecovery = nil
    }

    /// When the current sleep began, for the DEBUG drivers' sleep lengths.
    var asleepSince: Date? { policy.asleepSince }
}

extension SupermuxDevices {
    /// Every known remote Mac's link, read live (``devices`` is a snapshot
    /// refreshed after link events).
    var links: [DeviceLink] {
        devices.compactMap { provider(for: $0.machine)?.link }
    }
}

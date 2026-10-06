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
///   first for at most 4 s, a second under the dials' 5 s wait, and without
///   fresh ones the rebuild runs again at the next network change or when
///   credentials arrive, within 30 s of the wake), iroh is told the network
///   changed, the route
///   switcher gives direct a fresh chance (hold-off cleared, probes now), the
///   idle direct lane is rebound, and links waiting in a backoff dial at
///   once. Dials wait for the rebuild, at most 5 s. A viewing Mac's sizing
///   report kept past its connection's close waits a whole grace again
///   (``SupermuxMacViewerCloseGrace``), so that Mac's redial comes first, and
///   a mirror holding typing while its link is down holds a whole window
///   again (``SupermuxMirrorInputHold``), so the first keys after the wake
///   wait for the redial.
/// - **A network change** (interfaces or IPv4 addresses, Tailscale's `utun`
///   too, debounced 1 s) recovers the same way while awake, without the
///   rebuild (unless the wake's has not run yet) or the redials.
/// - **Fresh relay credentials** (``credentialsReceived()``) run a rebuild
///   the wake kept for lack of them. One rebuild runs at a time; a network
///   change or credentials during one make it go once more if it kept the
///   endpoint.
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
    /// How long the rebuild waits for a fresh relay credential: a second
    /// under ``rebuildWaitLimit``, so its close and bind are done before the
    /// waiting dials go.
    static let credentialWaitLimit: Duration = .seconds(4)

    /// What the last recovery did, for the DEBUG drivers.
    struct RecoveryRecord {
        let recovery: SupermuxWakePolicy.Recovery
        /// `rebuilt`, `rebuilt-after-refresh`, `no-endpoint`,
        /// `kept-expired-credentials`, `running` (another recovery's rebuild
        /// was under way) or `kept` (no rebuild planned).
        let main: String
        let laneRebuilt: Bool
        let redialed: Int
    }

    private let journal: IrxJournal
    private var policy = SupermuxWakePolicy()
    private var rebuilding = false
    /// The rebuild `rebuilding` belongs to; an older one finishing never clears a newer one's.
    private var rebuildToken: UInt64 = 0
    /// A rebuild is running (it may outlast the dials' wait).
    private var rebuildRunning = false
    /// A network change or credentials came while it ran: if it kept the
    /// endpoint, it goes once more.
    private var rebuildAgain = false
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
        SupermuxMacViewerCloseGrace.restartAfterWake()
        SupermuxMirrorInputHold.restartAfterWake()
        displayTask?.cancel()
        displayTask = nil
        let token = recovery.rebuildsMainEndpoint ? beginRebuild() : nil
        return Task { await recover(recovery, gate: token, redialsWaitingLinks: true) }
    }

    /// The network path changed; recovers after the burst settles. Returns
    /// the debounce, which a later change cancels.
    @discardableResult
    func networkChanged() -> Task<Void, Never> {
        networkTask?.cancel()
        let task = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.networkDebounce)) != nil, let self else { return }
            guard let recovery = policy.networkChanged(at: Date()) else { return }
            await recover(recovery, gate: nil, redialsWaitingLinks: false)
        }
        networkTask = task
        return task
    }

    /// Fresh relay credentials arrived (`MobileHostIrxRuntime`): a rebuild
    /// the last wake kept for lack of them runs now; one still running sees
    /// them.
    func credentialsReceived() {
        guard let recovery = policy.credentialsReceived(at: Date()) else { return }
        guard !rebuildRunning else {
            rebuildAgain = true
            return
        }
        Task { await recover(recovery, gate: nil, redialsWaitingLinks: false) }
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

    /// `gate`: the dial gate a wake closed for its rebuild.
    private func recover(_ recovery: SupermuxWakePolicy.Recovery, gate token: UInt64?, redialsWaitingLinks: Bool) async {
        var main = "kept"
        if recovery.rebuildsMainEndpoint { main = await rebuildIfWanted(gate: token) }
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

    /// Rebuilds the main endpoint while the last wake still wants it, one
    /// run at a time: a trigger during a run marks ``rebuildAgain`` and
    /// returns `running`; a run that kept the endpoint goes once more when
    /// one came.
    private func rebuildIfWanted(gate token: UInt64?) async -> String {
        guard !rebuildRunning else {
            rebuildAgain = true
            if let token { endRebuild(token) }
            return "running"
        }
        rebuildRunning = true
        defer { rebuildRunning = false }
        var gate = token
        var main = "kept"
        while policy.wantsRebuild(at: Date()) {
            rebuildAgain = false
            let outcome = await gatedRebuild(token: gate ?? beginRebuild())
            gate = nil
            policy.rebuildFinished(keptEndpoint: outcome == .keptExpiredCredentials)
            main = outcome.rawValue
            guard outcome == .keptExpiredCredentials, rebuildAgain else { break }
        }
        if let gate { endRebuild(gate) }
        return main
    }

    /// One rebuild, with dials waiting for the new endpoint, but never
    /// longer than ``rebuildWaitLimit``.
    private func gatedRebuild(token: UInt64) async -> SupermuxMainEndpointRebuild.Outcome {
        let limit = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.rebuildWaitLimit)) != nil else { return }
            self?.endRebuild(token)
        }
        let outcome = await Self.rebuildMainEndpoint()
        limit.cancel()
        endRebuild(token)
        return outcome
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
    /// after a night they always have) within ``credentialWaitLimit``; or not
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
        return await SupermuxMainEndpointRebuild.run(steps, limit: credentialWaitLimit)
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
        rebuildAgain = false
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

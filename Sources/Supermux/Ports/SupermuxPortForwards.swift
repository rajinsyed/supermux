import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit
import SupermuxMobileCore

/// Forwards other Macs' ports to `localhost` on this Mac, so a server started
/// in another Mac's workspace opens here in any browser, the iOS Simulator or
/// any other app.
///
/// Each Mac lists the ports of its own workspaces (`mobile.supermux.ports.list`,
/// pushed with `supermux.ports.updated`), and its other loopback ports. With
/// the setting on (``SupermuxDevicesSettings/forwardPorts``), every listed
/// workspace port ≥ 1024 of a workspace mirrored here is forwarded
/// automatically; a mirror browser opening a listed port starts a same-port
/// forward of it on demand (``forwardOnDemand(machine:remotePort:)``); the user
/// can also forward any port by hand, and stop or resume one
/// (``SupermuxPortForwardPlan`` decides). A forward listens on the remote
/// port itself when it is free here, else where it listened last, else on the
/// next free one (``SupermuxLoopbackPortListener``); a port in use here is
/// never taken. When a Mac goes offline its forwards stop listening and wait;
/// they come back when it reconnects, the same way.
/// While a connected Mac does not answer (its capabilities unknown, a port
/// listing that failed) they wait too, and it is asked again after 1 s,
/// doubling up to 30 s (``retryDelay(after:)``), for as long as it stays
/// connected.
@MainActor
@Observable
final class SupermuxPortForwards {
    typealias Key = SupermuxPortForwardPlan.Key

    enum Origin: String, Sendable {
        case automatic
        /// A same-port forward a mirror browser started for a page
        /// (``SupermuxPortForwards/forwardOnDemand(machine:remotePort:)``).
        case onDemand = "on_demand"
        case manual
    }

    enum State: Equatable, Sendable {
        case starting
        case active(localPort: Int)
        /// The user stopped it.
        case stopped
        /// Its Mac is offline or cannot forward right now.
        case waiting
        case failed(String)
    }

    struct Forward: Equatable, Sendable {
        let key: Key
        var origin: Origin
        var state: State
        /// The local port it last listened on, preferred when it starts again.
        var lastLocalPort: Int?
        /// The owner's workspaces (canonical ids) listing the port.
        var workspaceIDs: [String]
        /// The owner's terminal title for the port (usually the command).
        var terminalTitle: String?

        var localPort: Int? {
            if case .active(let port) = state { return port }
            return nil
        }
    }

    /// Debounce for reconcile triggers (catalog churn arrives in bursts).
    nonisolated static let debounce: Duration = .milliseconds(200)
    /// At most one port listing fetch per Mac in this window.
    nonisolated static let fetchThrottle: Duration = .milliseconds(500)
    /// How far above the remote port a moved forward looks for a free port.
    nonisolated static let nearbyPortRange = 50
    /// The longest wait before a Mac that did not answer is asked again.
    nonisolated static let longestRetryDelay = 30
    /// When a Mac is asked for its ports again, counted from the moment a
    /// forward's port left its listing (its server went away): 3, 10 and 30 s
    /// later. A restart may never be announced: a quick one keeps the
    /// owner's sidebar ports as they were (it keeps a port through two missed
    /// scans), so it sends no `supermux.ports.updated`, and a server outside its
    /// workspaces' terminals never does. Not gated on this app being active:
    /// forwards serve other apps too.
    nonisolated static let followUpDelays: [Duration] = [.seconds(3), .seconds(10), .seconds(30)]

    private(set) var forwards: [Key: Forward] = [:]
    /// Each available Mac's last port listing.
    private(set) var hostPorts: [SurfaceMachineID: SupermuxPortsListDTO] = [:]
    /// Whether each Mac can forward right now (connected Macs only;
    /// `.unreachable` while it is being asked again).
    private(set) var availability: [SurfaceMachineID: SupermuxDeviceTunnelAvailability] = [:]

    @ObservationIgnored private let devices: SupermuxDevices
    @ObservationIgnored private let index: SupermuxDeviceWorkspaceIndex
    @ObservationIgnored private let settings: SupermuxDevicesSettings
    @ObservationIgnored private var listeners: [Key: SupermuxLoopbackPortListener] = [:]
    @ObservationIgnored private var startTasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var manual: Set<Key> = []
    @ObservationIgnored private var onDemand: Set<Key> = []
    @ObservationIgnored private var dismissed: Set<Key> = []
    /// The workspaces that listed each port the user stopped, at the stop.
    @ObservationIgnored private var stoppedWorkspaces: [Key: Set<String>] = [:]
    /// Each key's listener that is still releasing its port; a new start of
    /// the key waits for it (the port it held may be the one it wants).
    @ObservationIgnored private var stopping: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetching: Set<SurfaceMachineID> = []
    @ObservationIgnored private var fetchAgain: Set<SurfaceMachineID> = []
    /// Listing fetches that failed in a row, per Mac (the next retry's delay).
    @ObservationIgnored private var fetchFailures: [SurfaceMachineID: Int] = [:]
    /// Each Mac's pending retry of a failed listing; any other fetch request replaces it.
    @ObservationIgnored private var fetchRetries: [SurfaceMachineID: Task<Void, Never>] = [:]
    /// Each connected Mac's availability check (it repeats while unreachable).
    @ObservationIgnored private var availabilityChecks: [SurfaceMachineID: Task<Void, Never>] = [:]
    /// Each Mac's follow-up fetches after a forward's port left its listing.
    @ObservationIgnored private var followUps: [SurfaceMachineID: Task<Void, Never>] = [:]
    /// One fetch of a Mac's listing (``startFetch(_:)``).
    private struct ListingFetch {
        let generation: Int
        let started: ContinuousClock.Instant
        let task: Task<Void, Never>
    }

    /// Each Mac's listing fetch in flight, how many were started, and when the last one started.
    @ObservationIgnored private var inFlight: [SurfaceMachineID: ListingFetch] = [:]
    @ObservationIgnored private var fetchGenerations: [SurfaceMachineID: Int] = [:]
    @ObservationIgnored private var lastFetchStart: [SurfaceMachineID: ContinuousClock.Instant] = [:]
    /// Each Mac's latest fetch, and the latest whose reply was applied: an
    /// older reply is dropped.
    @ObservationIgnored private var fetchSequence: [SurfaceMachineID: Int] = [:]
    @ObservationIgnored private var appliedSequence: [SurfaceMachineID: Int] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var revisionTask: Task<Void, Never>?
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastAutoForward: Bool?
    /// Called after every change of forwards or listings (the mirror chips and pills).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    #if DEBUG
    /// E2E (`supermux.devices.ports.follow_ups`): false skips the follow-up
    /// fetches, so a step can tell another path from them.
    @ObservationIgnored var followUpsEnabled = true
    #endif

    init(devices: SupermuxDevices, index: SupermuxDeviceWorkspaceIndex, settings: SupermuxDevicesSettings) {
        self.devices = devices
        self.index = index
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Starts following devices, mirrors and the setting. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        lastAutoForward = settings.forwardPorts
        eventsTask = Task { @MainActor [weak self, devices] in
            for await event in devices.events() { self?.handle(event) }
        }
        revisionTask = Task { @MainActor [weak self, devices] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = devices.revision } onChange: { continuation.resume() }
                }
                self?.scheduleReconcile()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingMayHaveChanged() }
        }
        // Links that connected before this started sent their event already.
        for device in devices.devices where device.isConnected {
            linkConnected(device.machine)
        }
    }

    // MARK: - User actions

    /// Forwards a port of `machine` by hand (Forward a Port…, Forward to This Mac).
    func forward(machine: SurfaceMachineID, remotePort: Int) async {
        let key = Key(machine: machine, remotePort: remotePort)
        dismissed.remove(key)
        stoppedWorkspaces[key] = nil
        manual.insert(key)
        if case .failed = forwards[key]?.state { forwards[key]?.state = .waiting }
        reconcile()
    }

    /// Stops a forward and frees its local port. An automatic or on-demand
    /// one stays stopped (``SupermuxPortForwardPlan``: until Resume, across its
    /// server's restarts); a manual one goes.
    func stop(machine: SurfaceMachineID, remotePort: Int) async {
        let key = Key(machine: machine, remotePort: remotePort)
        manual.remove(key)
        dismissed.insert(key)
        stoppedWorkspaces[key] = Set(forwards[key]?.workspaceIDs ?? [])
        stopListenerLater(key)
        reconcile()
        await stopping[key]?.value
    }

    /// Starts a stopped forward again.
    func resume(machine: SurfaceMachineID, remotePort: Int) async {
        let key = Key(machine: machine, remotePort: remotePort)
        guard let origin = forwards[key]?.origin, origin != .manual else {
            await forward(machine: machine, remotePort: remotePort)
            return
        }
        dismissed.remove(key)
        stoppedWorkspaces[key] = nil
        forwards[key]?.state = .waiting
        reconcile()
    }

    /// The Settings toggle: automatic forwarding on or off, applied at once.
    func setAutoForward(_ enabled: Bool) {
        settings.forwardPorts = enabled
        lastAutoForward = enabled
        reconcile()
    }

    /// The local port `remotePort` of `machine` is reachable at here, if forwarded.
    func localPort(machine: SurfaceMachineID, remotePort: Int) -> Int? {
        forwards[Key(machine: machine, remotePort: remotePort)]?.localPort
    }

    /// Fetches the port listing of `machine` (every connected Mac when nil) now.
    func refresh(machine: SurfaceMachineID? = nil) {
        let machines = machine.map { [$0] } ?? devices.devices.filter(\.isConnected).map(\.machine)
        for machine in machines { requestFetch(machine, after: .zero) }
    }

    // MARK: - On demand

    /// Whether `machine`'s latest listing has `port`: a workspace's, or one
    /// of its other loopback ports.
    func lists(machine: SurfaceMachineID, port: Int) -> Bool {
        guard let listing = hostPorts[machine] else { return false }
        return listing.ports.contains { $0.port == port } || (listing.otherPorts ?? []).contains(port)
    }

    #if DEBUG
    /// The user's stops and the workspaces each recorded (E2E, `ports.list`).
    var debugStops: [(key: Key, workspaces: [String])] {
        dismissed.sorted { $0.description < $1.description }.map { ($0, (stoppedWorkspaces[$0] ?? []).sorted()) }
    }
    #endif

    /// Whether the user stopped the forward of `remotePort` (it stays stopped
    /// until Resume, across its server's restarts).
    func isStoppedByUser(machine: SurfaceMachineID, remotePort: Int) -> Bool {
        let key = Key(machine: machine, remotePort: remotePort)
        return dismissed.contains(key) || forwards[key]?.state == .stopped
    }

    /// Returns once the listener of `remotePort`'s forward that is being
    /// stopped (if any) has released its local port.
    func released(machine: SurfaceMachineID, remotePort: Int) async {
        await stopping[Key(machine: machine, remotePort: remotePort)]?.value
    }

    /// Whether `machine`'s latest listing has `port` as one of its workspaces'.
    func listsInWorkspace(machine: SurfaceMachineID, port: Int) -> Bool {
        hostPorts[machine]?.ports.contains { $0.port == port } ?? false
    }

    /// Fetches `machine`'s listing for a navigation held since `start`; returns
    /// once a listing asked for at or after `start` is in (or failed). It joins
    /// such a fetch when one is in flight or done, so a burst of navigations asks
    /// that Mac a few times, not once each; `wanted` false (the navigation was
    /// dropped) ends the wait without asking.
    func fetchListingNow(
        _ machine: SurfaceMachineID, since start: ContinuousClock.Instant, while wanted: () -> Bool = { true }
    ) async {
        // Each fetch is awaited at most once, by its generation: a loop that found
        // a finished fetch still registered and awaited it again would never
        // suspend (a finished task's value returns at once) and spin the main actor.
        var awaited = 0
        while wanted() {
            if let running = inFlight[machine], running.generation > awaited {
                awaited = running.generation
                await running.task.value
                if running.started >= start { return }
                continue
            }
            if let last = lastFetchStart[machine], last >= start { return }
            await startFetch(machine).task.value
            return
        }
    }

    /// Fetches `machine`'s listing after any fetch in flight (one at a time,
    /// so replies come in order).
    private func sharedFetch(_ machine: SurfaceMachineID) async {
        await fetchListingNow(machine, since: .now)
    }

    /// Starts a fetch of `machine`'s listing and registers it as the one in
    /// flight. It unregisters itself as soon as it is done, before anyone
    /// awaiting it resumes, so no waiter ever finds it finished and registered.
    private func startFetch(_ machine: SurfaceMachineID) -> ListingFetch {
        let generation = (fetchGenerations[machine] ?? 0) + 1
        fetchGenerations[machine] = generation
        let started = ContinuousClock.now
        lastFetchStart[machine] = started
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            await self?.fetch(machine)
            if self?.inFlight[machine]?.generation == generation { self?.inFlight[machine] = nil }
        }
        let fetch = ListingFetch(generation: generation, started: started, task: task)
        inFlight[machine] = fetch
        return fetch
    }

    /// Starts a same-port forward of `remotePort` for a mirror browser's page,
    /// unless the user stopped it: a new one (on demand: kept while that Mac
    /// lists the port, also with automatic forwarding off, and stopped like an
    /// automatic one), or the existing one listening on another port or
    /// failed, restarted so it tries `remotePort` first. The caller checked
    /// that `machine` lists the port and that it is free here. False when no
    /// forward will start.
    func forwardOnDemand(machine: SurfaceMachineID, remotePort: Int) -> Bool {
        let key = Key(machine: machine, remotePort: remotePort)
        guard availability[machine] == .available, !dismissed.contains(key),
              remotePort >= SupermuxPortForwardPlan.lowestAutomaticPort else { return false }
        guard let forward = forwards[key] else {
            onDemand.insert(key)
            reconcile()
            return forwards[key] != nil
        }
        switch forward.state {
        case .stopped:
            return false
        case .starting, .waiting:
            return true
        case .active(let port) where port == remotePort:
            return true
        case .active, .failed:
            stopListenerLater(key)
            forwards[key]?.state = .waiting
            reconcile()
            return true
        }
    }

    // MARK: - Triggers

    private func handle(_ event: SupermuxDeviceEvent) {
        switch event {
        case .linkConnected(let machine):
            linkConnected(machine)
        case .linkLost(let machine):
            linkLost(machine)
        case .topic(let machine, let topic, _) where topic == .portsUpdated:
            requestFetch(machine, after: Self.fetchThrottle)
        case .topic:
            break
        }
    }

    private func linkConnected(_ machine: SurfaceMachineID) {
        var retried = false
        for (key, forward) in forwards where key.machine == machine {
            if case .failed = forward.state {
                forwards[key]?.state = .waiting
                retried = true
            }
        }
        // A listing that comes back unchanged reconciles nothing, so a failed
        // forward that waits again is started here (it listens only while
        // that Mac is available).
        if retried { scheduleReconcile() }
        checkAvailability(machine)
    }

    private func linkLost(_ machine: SurfaceMachineID) {
        availabilityChecks.removeValue(forKey: machine)?.cancel()
        fetchRetries.removeValue(forKey: machine)?.cancel()
        followUps.removeValue(forKey: machine)?.cancel()
        // A reply to a fetch sent before the drop must not land after the reconnect.
        appliedSequence[machine] = fetchSequence[machine]
        fetchFailures[machine] = nil
        availability[machine] = nil
        hostPorts[machine] = nil
        reconcile()
    }

    /// Learns whether `machine` can forward, and asks again after
    /// ``retryDelay(after:)`` for as long as the answer is `.unreachable` and
    /// the link stays connected. One check per Mac: a new link connect
    /// replaces it and a link loss ends it.
    private func checkAvailability(_ machine: SurfaceMachineID) {
        availabilityChecks[machine]?.cancel()
        availabilityChecks[machine] = Task { @MainActor [weak self] in
            var failures = 0
            while true {
                // Cancelled while waiting: a newer check runs, or the link went.
                if failures > 0, (try? await Task.sleep(for: Self.retryDelay(after: failures))) == nil { return }
                let availability = await SupermuxDeviceTunnelClient.availability(of: machine)
                // The link dropped (its linkLost ran) or connected again (a newer check runs).
                guard let self, !Task.isCancelled, self.devices.device(for: machine)?.isConnected == true else { return }
                self.apply(availability, of: machine)
                guard availability == .unreachable else { return }
                failures += 1
            }
        }
    }

    /// Stores what a check found: an available Mac's listing is fetched,
    /// any other Mac's is dropped.
    private func apply(_ reason: SupermuxDeviceTunnelAvailability, of machine: SurfaceMachineID) {
        availability[machine] = reason
        fetchFailures[machine] = nil
        if reason == .available {
            requestFetch(machine, after: .zero)
        } else {
            hostPorts[machine] = nil
            reconcile()
        }
    }

    private func settingMayHaveChanged() {
        let autoForward = settings.forwardPorts
        guard autoForward != lastAutoForward else { return }
        lastAutoForward = autoForward
        reconcile()
    }

    /// Fetches a Mac's listing after `delay`; pokes during a fetch fetch once
    /// more after it. A failed fetch is tried again after ``retryDelay(after:)``
    /// while the Mac stays available (a poke alone may never come: the owner
    /// sends one only when its ports or workspaces change).
    private func requestFetch(_ machine: SurfaceMachineID, after delay: Duration) {
        guard !fetching.contains(machine) else {
            fetchAgain.insert(machine)
            return
        }
        fetchRetries.removeValue(forKey: machine)?.cancel()
        fetching.insert(machine)
        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            await self.sharedFetch(machine)
            self.fetching.remove(machine)
            if self.fetchAgain.remove(machine) != nil {
                self.requestFetch(machine, after: Self.fetchThrottle)
            } else if let failures = self.fetchFailures[machine], self.availability[machine] == .available {
                self.retryFetch(machine, after: Self.retryDelay(after: failures))
            }
        }
    }

    /// Fetches a listing that failed again after `delay`. The wait holds no
    /// fetch slot: a poke, a new availability verdict or a reconnect fetches
    /// at once instead (``requestFetch(_:after:)`` replaces it), and a link
    /// loss ends it.
    private func retryFetch(_ machine: SurfaceMachineID, after delay: Duration) {
        fetchRetries[machine] = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled, let self else { return }
            self.fetchRetries[machine] = nil
            self.requestFetch(machine, after: .zero)
        }
    }

    private func fetch(_ machine: SurfaceMachineID) async {
        guard availability[machine] == .available else { return }
        let sequence = (fetchSequence[machine] ?? 0) + 1
        fetchSequence[machine] = sequence
        do {
            // Its other loopback ports too: a server outside its workspaces'
            // terminals (an agent's, Docker) is still that Mac's (a mirror page
            // of it loads as written; forwarded on demand, never automatically).
            let listing = try await devices.request(
                SupermuxMobileMethod.portsList.rawValue, params: ["include_other": true],
                on: machine, as: SupermuxPortsListDTO.self
            )
            // Gone meanwhile, or older than a listing already applied (one from
            // before a reconnect).
            guard availability[machine] == .available, sequence > (appliedSequence[machine] ?? 0) else { return }
            appliedSequence[machine] = sequence
            fetchFailures[machine] = nil
            // The same listing again (a follow-up or a poke that changed
            // nothing here): the forwards already follow it.
            guard hostPorts[machine] != listing else { return }
            hostPorts[machine] = listing
        } catch {
            fetchFailures[machine, default: 0] += 1
            #if DEBUG
            cmuxDebugLog("supermux.ports listing of \(machine.rawValue) failed: \(error)")
            #endif
        }
        reconcile()
    }

    /// Asks `machine` for its ports again at each of ``followUpDelays`` from
    /// now (a newer call starts over), so a restarted server is found without a
    /// poke: its forward comes back, and an open mirror tab of it gets one
    /// (``SupermuxSamePortForwardGate/forwardOpenTabs()``).
    private func followUp(_ machine: SurfaceMachineID) {
        #if DEBUG
        guard followUpsEnabled else { return }
        #endif
        followUps[machine]?.cancel()
        let start = ContinuousClock.now
        followUps[machine] = Task { @MainActor [weak self] in
            for delay in Self.followUpDelays {
                guard (try? await Task.sleep(until: start + delay, clock: .continuous)) != nil, let self else { return }
                self.requestFetch(machine, after: .zero)
            }
        }
    }

    /// How long the `failures`-th failed check or fetch in a row waits before
    /// the next: 1 s, doubling, at most ``longestRetryDelay``.
    nonisolated static func retryDelay(after failures: Int) -> Duration {
        .seconds(min(longestRetryDelay, 1 << min(max(failures - 1, 0), 5)))
    }

    func scheduleReconcile() {
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            self.reconcile()
        }
    }

    // MARK: - Reconcile

    /// Applies the plan: creates, keeps and drops forwards, and starts or
    /// stops their listeners.
    func reconcile() {
        scheduled?.cancel()
        scheduled = nil
        let listings = currentListings()
        let decision = SupermuxPortForwardPlan.decide(SupermuxPortForwardPlan.Input(
            autoForward: settings.forwardPorts,
            listings: listings.mapValues(\.plan),
            mirrored: Set(index.mirrors().map(\.ref)),
            manual: manual,
            onDemand: onDemand,
            dismissed: dismissed,
            stoppedWorkspaces: stoppedWorkspaces,
            existing: Set(forwards.keys)
        ))
        dismissed = decision.dismissed
        stoppedWorkspaces = stoppedWorkspaces.filter { dismissed.contains($0.key) }
        onDemand = decision.onDemand
        var serverWentAway: Set<SurfaceMachineID> = []
        for key in forwards.keys where !decision.kept.contains(key) {
            if listings[key.machine]?.lists(key.remotePort) == false { serverWentAway.insert(key.machine) }
            forwards[key] = nil
            stopListenerLater(key)
        }
        serverWentAway.forEach(followUp)
        for key in decision.kept {
            var forward = forwards[key] ?? Forward(
                key: key, origin: .automatic, state: .waiting, lastLocalPort: nil, workspaceIDs: [], terminalTitle: nil
            )
            if manual.contains(key) {
                forward.origin = .manual
            } else if decision.automatic.contains(key) {
                forward.origin = .automatic
            } else if decision.onDemand.contains(key) {
                forward.origin = .onDemand
            }
            if let detail = listings[key.machine]?.detail[key.remotePort] {
                forward.workspaceIDs = detail.workspaceIDs
                forward.terminalTitle = detail.terminalTitle
            }
            let listens = decision.run.contains(key) && availability[key.machine] == .available
            if decision.paused.contains(key) {
                forward.state = .stopped
            } else if !listens {
                forward.state = .waiting
            } else if forward.state == .stopped {
                forward.state = .waiting
            }
            if forwards[key] != forward { forwards[key] = forward }
            if forward.state == .stopped || forward.state == .waiting {
                stopListenerLater(key)
            }
            if listens, forward.state == .waiting {
                startListener(key)
            }
        }
        onChange?()
    }

    /// The listings the plan sees: each available Mac's fetched listing, and
    /// an empty one for a connected Mac that cannot forward. A Mac that does
    /// not answer right now has none, so its forwards wait as they are.
    private func currentListings() -> [SurfaceMachineID: MachineListing] {
        var listings: [SurfaceMachineID: MachineListing] = [:]
        for (machine, reason) in availability {
            switch reason {
            case .available:
                if let dto = hostPorts[machine] { listings[machine] = MachineListing(dto) }
            case .needsUpdate, .noDirectLink:
                listings[machine] = MachineListing(nil)
            case .offline, .unreachable:
                break
            }
        }
        return listings
    }

    // MARK: - Listeners

    private func startListener(_ key: Key) {
        guard listeners[key] == nil, startTasks[key] == nil, var forward = forwards[key] else { return }
        forward.state = .starting
        forwards[key] = forward
        let candidates = Self.candidatePorts(remotePort: key.remotePort, last: forward.lastLocalPort)
        let releasing = stopping[key]
        startTasks[key] = Task { @MainActor [weak self] in
            if let releasing {
                await releasing.value
                if self?.stopping[key] == releasing { self?.stopping[key] = nil }
            }
            let opened = await SupermuxLoopbackPortListener.open(
                machine: key.machine, remotePort: key.remotePort, candidates: candidates
            )
            // Stopped, dropped or restarted meanwhile: give the port back.
            guard let self, !Task.isCancelled, self.forwards[key]?.state == .starting else {
                await opened?.listener.stop()
                return
            }
            self.startTasks[key] = nil
            if let opened {
                self.listeners[key] = opened.listener
                self.forwards[key]?.state = .active(localPort: opened.port)
                self.forwards[key]?.lastLocalPort = opened.port
            } else {
                self.forwards[key]?.state = .failed(Self.noFreePortMessage(near: key.remotePort))
            }
            self.onChange?()
        }
    }

    /// Takes the listener of `key` (or cancels its start) so a new one can
    /// start; the caller stops it.
    private func detachListener(_ key: Key) -> SupermuxLoopbackPortListener? {
        startTasks.removeValue(forKey: key)?.cancel()
        return listeners.removeValue(forKey: key)
    }

    /// Stops the key's listener in the background; a new start of the key
    /// waits until it released its port (``stopping``).
    private func stopListenerLater(_ key: Key) {
        guard let listener = detachListener(key) else { return }
        let previous = stopping[key]
        stopping[key] = Task {
            await previous?.value
            await listener.stop()
        }
    }

    /// The local ports a forward tries, in order: the remote port itself, so
    /// a forward that moved because it was busy here comes back once it is
    /// free (a mirror page of it then loads as written, keeping its own
    /// origin); where it last listened, so while the remote port stays busy
    /// here it keeps its local port; then the next ports above it.
    nonisolated static func candidatePorts(remotePort: Int, last: Int?) -> [Int] {
        var ports: [Int] = []
        for port in [remotePort, last].compactMap({ $0 }) + Array(remotePort + 1...remotePort + nearbyPortRange)
            where (1...65_535).contains(port) && !ports.contains(port) {
            ports.append(port)
        }
        return ports
    }

    static func noFreePortMessage(near port: Int) -> String {
        String(localized: "supermux.ports.failed.noFreePort", defaultValue: "No free local port near \(String(port))")
    }
}

/// One Mac's listing as the forwards need it.
private struct MachineListing {
    struct Detail {
        var workspaceIDs: [String]
        var terminalTitle: String?
    }

    var detail: [Int: Detail] = [:]

    var otherPorts: Set<Int> = []

    init(_ dto: SupermuxPortsListDTO?) {
        otherPorts = Set(dto?.otherPorts ?? [])
        for port in dto?.ports ?? [] {
            let workspaceID = SupermuxRemoteWorkspaceRef.canonicalWorkspaceID(port.workspaceID)
            var entry = detail[port.port] ?? Detail(workspaceIDs: [], terminalTitle: nil)
            if !entry.workspaceIDs.contains(workspaceID) { entry.workspaceIDs.append(workspaceID) }
            entry.terminalTitle = entry.terminalTitle ?? port.terminalTitle
            detail[port.port] = entry
        }
    }

    func lists(_ port: Int) -> Bool {
        detail[port] != nil || otherPorts.contains(port)
    }

    var plan: SupermuxPortForwardPlan.Listing {
        SupermuxPortForwardPlan.Listing(workspaces: detail.mapValues { Set($0.workspaceIDs) }, otherPorts: otherPorts)
    }
}

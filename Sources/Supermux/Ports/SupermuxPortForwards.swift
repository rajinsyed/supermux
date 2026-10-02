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
/// pushed with `supermux.ports.updated`). With the setting on
/// (``SupermuxDevicesSettings/forwardPorts``), every listed port ≥ 1024 of a
/// workspace mirrored here is forwarded automatically; the user can also
/// forward any port by hand, and stop or resume one
/// (``SupermuxPortForwardPlan`` decides). A forward listens on the remote
/// port itself when it is free here, else on the next free one
/// (``SupermuxLoopbackPortListener``); a port in use here is never taken.
/// When a Mac goes offline its forwards stop listening and wait; they come
/// back, on the same local port when it is still free, when it reconnects.
@MainActor
@Observable
final class SupermuxPortForwards {
    typealias Key = SupermuxPortForwardPlan.Key

    enum Origin: String, Sendable {
        case automatic
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

    private(set) var forwards: [Key: Forward] = [:]
    /// Each available Mac's last port listing.
    private(set) var hostPorts: [SurfaceMachineID: SupermuxPortsListDTO] = [:]
    /// Whether each Mac can forward right now (connected Macs only).
    private(set) var availability: [SurfaceMachineID: SupermuxDeviceTunnelAvailability] = [:]

    @ObservationIgnored private let devices: SupermuxDevices
    @ObservationIgnored private let index: SupermuxDeviceWorkspaceIndex
    @ObservationIgnored private let settings: SupermuxDevicesSettings
    @ObservationIgnored private var listeners: [Key: SupermuxLoopbackPortListener] = [:]
    @ObservationIgnored private var startTasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var manual: Set<Key> = []
    @ObservationIgnored private var dismissed: Set<Key> = []
    @ObservationIgnored private var fetching: Set<SurfaceMachineID> = []
    @ObservationIgnored private var fetchAgain: Set<SurfaceMachineID> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var revisionTask: Task<Void, Never>?
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastAutoForward: Bool?
    /// Called after every change of forwards or listings (the mirror chips and pills).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

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
        manual.insert(key)
        if case .failed = forwards[key]?.state { forwards[key]?.state = .waiting }
        reconcile()
    }

    /// Stops a forward and frees its local port. An automatic one stays
    /// stopped until its port leaves that Mac's listing; a manual one goes.
    func stop(machine: SurfaceMachineID, remotePort: Int) async {
        let key = Key(machine: machine, remotePort: remotePort)
        manual.remove(key)
        dismissed.insert(key)
        let listener = detachListener(key)
        reconcile()
        await listener?.stop()
    }

    /// Starts a stopped forward again.
    func resume(machine: SurfaceMachineID, remotePort: Int) async {
        let key = Key(machine: machine, remotePort: remotePort)
        guard forwards[key]?.origin == .automatic else {
            await forward(machine: machine, remotePort: remotePort)
            return
        }
        dismissed.remove(key)
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
        for (key, forward) in forwards where key.machine == machine {
            if case .failed = forward.state { forwards[key]?.state = .waiting }
        }
        Task { @MainActor [weak self] in
            let availability = await SupermuxDeviceTunnelClient.availability(of: machine)
            // The link dropped again meanwhile: its linkLost already ran.
            guard let self, self.devices.device(for: machine)?.isConnected == true else { return }
            self.availability[machine] = availability
            if availability == .available {
                self.requestFetch(machine, after: .zero)
            } else {
                self.hostPorts[machine] = nil
                self.reconcile()
            }
        }
    }

    private func linkLost(_ machine: SurfaceMachineID) {
        availability[machine] = nil
        hostPorts[machine] = nil
        reconcile()
    }

    private func settingMayHaveChanged() {
        let autoForward = settings.forwardPorts
        guard autoForward != lastAutoForward else { return }
        lastAutoForward = autoForward
        reconcile()
    }

    /// Fetches a Mac's listing after `delay`; pokes during a fetch fetch once more after it.
    private func requestFetch(_ machine: SurfaceMachineID, after delay: Duration) {
        guard !fetching.contains(machine) else {
            fetchAgain.insert(machine)
            return
        }
        fetching.insert(machine)
        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            await self.fetch(machine)
            self.fetching.remove(machine)
            if self.fetchAgain.remove(machine) != nil {
                self.requestFetch(machine, after: Self.fetchThrottle)
            }
        }
    }

    private func fetch(_ machine: SurfaceMachineID) async {
        guard availability[machine] == .available else { return }
        do {
            let listing = try await devices.request(
                SupermuxMobileMethod.portsList.rawValue, on: machine, as: SupermuxPortsListDTO.self
            )
            guard availability[machine] == .available else { return }
            hostPorts[machine] = listing
        } catch {
            #if DEBUG
            cmuxDebugLog("supermux.ports listing of \(machine.rawValue) failed: \(error)")
            #endif
        }
        reconcile()
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
            dismissed: dismissed,
            existing: Set(forwards.keys)
        ))
        dismissed = decision.dismissed
        for key in forwards.keys where !decision.kept.contains(key) {
            forwards[key] = nil
            stopListenerLater(key)
        }
        for key in decision.kept {
            var forward = forwards[key] ?? Forward(
                key: key, origin: .automatic, state: .waiting, lastLocalPort: nil, workspaceIDs: [], terminalTitle: nil
            )
            forward.origin = manual.contains(key) ? .manual : .automatic
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
    /// an empty one for a connected Mac that cannot forward.
    private func currentListings() -> [SurfaceMachineID: MachineListing] {
        var listings: [SurfaceMachineID: MachineListing] = [:]
        for (machine, reason) in availability {
            if reason == .available {
                if let dto = hostPorts[machine] { listings[machine] = MachineListing(dto) }
            } else {
                listings[machine] = MachineListing(nil)
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
        startTasks[key] = Task { @MainActor [weak self] in
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

    private func stopListenerLater(_ key: Key) {
        guard let listener = detachListener(key) else { return }
        Task { await listener.stop() }
    }

    /// The local ports a forward tries, in order: where it last listened, the
    /// remote port itself, then the next ports above it.
    nonisolated static func candidatePorts(remotePort: Int, last: Int?) -> [Int] {
        var ports: [Int] = []
        for port in [last, remotePort].compactMap({ $0 }) + Array(remotePort + 1...remotePort + nearbyPortRange)
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

    init(_ dto: SupermuxPortsListDTO?) {
        for port in dto?.ports ?? [] {
            let workspaceID = SupermuxRemoteWorkspaceRef.canonicalWorkspaceID(port.workspaceID)
            var entry = detail[port.port] ?? Detail(workspaceIDs: [], terminalTitle: nil)
            if !entry.workspaceIDs.contains(workspaceID) { entry.workspaceIDs.append(workspaceID) }
            entry.terminalTitle = entry.terminalTitle ?? port.terminalTitle
            detail[port.port] = entry
        }
    }

    var plan: SupermuxPortForwardPlan.Listing {
        SupermuxPortForwardPlan.Listing(workspaces: detail.mapValues { Set($0.workspaceIDs) })
    }
}

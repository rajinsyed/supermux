import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit

/// Keeps exactly one local mirror workspace for every workspace on every
/// connected device (setting ``SupermuxDevicesSettings/autoMirror``), closes
/// mirrors whose remote workspace is gone, replaces orphaned mirrors, and
/// drives the mirror status projection.
///
/// Decisions come from the pure ``SupermuxMirrorReconciler``; this type
/// gathers its input (devices, records, mirrors, hidden set, in-flight opens)
/// and executes the plan:
/// - opens go through ``SupermuxDeviceWorkspaceOpener/openMirror(of:in:focus:createStarterTerminalIfEmpty:)``
///   one at a time, never focused, into the main window that already holds
///   that device's mirrors (else the preferred main window; never a new
///   window), then placed in the remote's order among its siblings;
/// - closes are local only, never prompt and never close anything remotely
///   (``SupermuxDeviceMirrorCloser/closeForCoordinator(_:)``).
///
/// Nothing runs until the startup session restore finished, so restored
/// placeholder mirrors (bound by `stableId`, or still holding pending restored
/// projections) always count as showing their workspace; stale bindings are
/// pruned once, right after that point.
@MainActor
final class SupermuxDeviceMirrorCoordinator {
    /// Debounce for reconcile triggers (catalog churn arrives in bursts).
    nonisolated static let debounce: Duration = .milliseconds(200)
    /// Back-off before retrying a ref whose open failed.
    nonisolated static let openRetryDelay: TimeInterval = 10

    private let devices: SupermuxDevices
    private let index: SupermuxDeviceWorkspaceIndex
    private let opener: SupermuxDeviceWorkspaceOpener
    private let hidden: SupermuxHiddenRemoteWorkspaces
    private let settings: SupermuxDevicesSettings
    private let closer: SupermuxDeviceMirrorCloser
    private let projector: SupermuxDeviceStatusProjector
    private let isReady: @MainActor () -> Bool

    private var reconciler = SupermuxMirrorReconciler()
    private var started = false
    private var scheduled: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var eventsTask: Task<Void, Never>?
    private var revisionTask: Task<Void, Never>?
    private var openQueue: [SupermuxRemoteWorkspaceRef] = []
    private var openTask: Task<Void, Never>?
    private var inFlight: Set<SupermuxRemoteWorkspaceRef> = []
    private var retryAfter: [SupermuxRemoteWorkspaceRef: Date] = [:]
    private var didPruneBindings = false
    private var lastAutoMirror: Bool?
    private(set) var lastPlan = SupermuxMirrorReconciler.Plan()
    private(set) var reconcileCount = 0
    private(set) var lastOpenError: String?

    init(
        devices: SupermuxDevices,
        index: SupermuxDeviceWorkspaceIndex,
        opener: SupermuxDeviceWorkspaceOpener,
        hidden: SupermuxHiddenRemoteWorkspaces,
        settings: SupermuxDevicesSettings,
        closer: SupermuxDeviceMirrorCloser,
        projector: SupermuxDeviceStatusProjector,
        isReady: @escaping @MainActor () -> Bool = SupermuxDeviceMirrorCoordinator.appIsReady
    ) {
        self.devices = devices
        self.index = index
        self.opener = opener
        self.hidden = hidden
        self.settings = settings
        self.closer = closer
        self.projector = projector
        self.isReady = isReady
    }

    /// Starts following devices, settings and windows. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        eventsTask = Task { @MainActor [weak self, devices] in
            for await _ in devices.events() { self?.scheduleReconcile() }
        }
        revisionTask = Task { @MainActor [weak self, devices] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = devices.revision } onChange: { continuation.resume() }
                }
                self?.scheduleReconcile()
            }
        }
        let names: [Notification.Name] = [UserDefaults.didChangeNotification, .mainWindowContextsDidChange]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handle(note) }
            })
        }
        scheduleReconcile()
    }

    /// Runs a reconcile pass after `delay` (coalesced with pending passes).
    func scheduleReconcile(after delay: Duration = SupermuxDeviceMirrorCoordinator.debounce) {
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            self.reconcile()
        }
    }

    /// Runs a pass now (tests and the `supermux.devices.reconcile` socket method).
    func reconcileNow() {
        scheduled?.cancel()
        scheduled = nil
        reconcile()
    }

    /// Whether an open is queued or running.
    var isOpening: Bool { openTask != nil || !openQueue.isEmpty }

    #if DEBUG
    /// Refs whose next auto-mirror open fails (E2E hook behind the
    /// `supermux.devices.fail_next_open` socket method).
    private var debugFailingOpens: Set<SupermuxRemoteWorkspaceRef> = []

    /// Makes the next auto-mirror open of `ref` fail, as a dropped link would.
    func debugFailNextOpen(of ref: SupermuxRemoteWorkspaceRef) {
        debugFailingOpens.insert(ref)
    }
    #endif

    /// Refs whose open is queued, in flight (here or from any other opener
    /// caller), backing off, or whose remote close is in flight.
    var busyRefs: Set<SupermuxRemoteWorkspaceRef> {
        let now = Date()
        let backingOff = retryAfter.filter { $0.value > now }.keys
        return inFlight.union(openQueue).union(backingOff)
            .union(opener.openingRefs)
            .union(closer.pendingRemoteCloses)
    }

    private func handle(_ note: Notification) {
        if note.name == UserDefaults.didChangeNotification {
            // Any defaults write lands here; only react to the setting.
            let autoMirror = settings.autoMirror
            guard autoMirror != lastAutoMirror else { return }
            lastAutoMirror = autoMirror
        }
        scheduleReconcile()
    }

    // MARK: - Reconcile

    private func reconcile() {
        guard isReady() else {
            #if DEBUG
            if reconcileCount == 0 { cmuxDebugLog("supermux.autoMirror waiting for session restore") }
            #endif
            scheduleReconcile(after: .milliseconds(500))
            return
        }
        if !didPruneBindings {
            didPruneBindings = true
            #if DEBUG
            cmuxDebugLog("supermux.autoMirror ready; pruning bindings (stored=\(index.storedBindings.count))")
            #endif
            index.pruneBindings()
        }
        reconcileCount += 1
        lastAutoMirror = settings.autoMirror
        let plan = reconciler.plan(makeInput())
        lastPlan = plan
        for close in plan.closes {
            guard let workspace = Workspace.liveWorkspace(id: close.localWorkspaceID) else { continue }
            #if DEBUG
            cmuxDebugLog("supermux.autoMirror close \(close.ref) local=\(close.localWorkspaceID) reason=\(close.reason.rawValue)")
            #endif
            closer.closeForCoordinator(workspace)
        }
        if !plan.unhide.isEmpty { hidden.remove(plan.unhide) }
        enqueueOpens(plan.opens)
        projector.refresh()
        if let followUp = plan.followUpAfter {
            scheduleReconcile(after: .milliseconds(Int(followUp * 1000)))
        }
    }

    private func makeInput() -> SupermuxMirrorReconciler.Input {
        let catalog = devices.catalog
        let deviceInputs = devices.devices.map { device in
            SupermuxMirrorReconciler.Device(
                machineID: device.machine.rawValue,
                isAuthoritative: device.isConnected && device.hasFetchedRecords,
                workspaces: devices.records(on: device.machine).map { record in
                    SupermuxMirrorReconciler.RemoteWorkspace(
                        workspaceID: record.id,
                        terminalCount: record.terminals.count,
                        sortIndex: record.sortIndex
                    )
                }
            )
        }
        let mirrors = index.mirrors().map { mirror in
            SupermuxMirrorReconciler.Mirror(
                ref: mirror.ref,
                localWorkspaceID: mirror.workspace.id,
                isBound: mirror.isBound,
                isProjected: catalog.projectionMachines(forWorkspace: mirror.workspace.id).contains(mirror.ref.machine)
            )
        }
        return SupermuxMirrorReconciler.Input(
            autoMirror: settings.autoMirror,
            devices: deviceInputs,
            mirrors: mirrors,
            hidden: hidden.refs,
            busy: busyRefs,
            now: Date()
        )
    }

    // MARK: - Opening

    private func enqueueOpens(_ refs: [SupermuxRemoteWorkspaceRef]) {
        let queued = Set(openQueue).union(inFlight)
        openQueue.append(contentsOf: refs.filter { !queued.contains($0) })
        guard openTask == nil, !openQueue.isEmpty else { return }
        openTask = Task { @MainActor [weak self] in
            await self?.drainOpenQueue()
            self?.openTask = nil
            self?.scheduleReconcile()
        }
    }

    private func drainOpenQueue() async {
        while !openQueue.isEmpty {
            let ref = openQueue.removeFirst()
            guard settings.autoMirror, !hidden.contains(ref), index.localWorkspace(showing: ref) == nil,
                  !opener.openingRefs.contains(ref),
                  let record = devices.record(for: ref), !record.terminals.isEmpty else { continue }
            guard let tabManager = SupermuxDeviceMirrorWindowPicker(index: index).tabManager(forDevice: ref.machine) else {
                // No main window yet: try again once one registers.
                openQueue.removeAll()
                return
            }
            inFlight.insert(ref)
            do {
                #if DEBUG
                if debugFailingOpens.remove(ref) != nil { throw SupermuxDeviceError.nothingToMirror(ref.description) }
                #endif
                let opened = try await opener.openMirror(of: ref, in: tabManager, focus: false)
                if !opened.reused { placeAmongSiblings(opened.workspace, ref: ref) }
                #if DEBUG
                cmuxDebugLog("supermux.autoMirror open \(ref) local=\(opened.workspace.id) reused=\(opened.reused)")
                #endif
                retryAfter[ref] = nil
                lastOpenError = nil
            } catch {
                #if DEBUG
                cmuxDebugLog("supermux.autoMirror open failed \(ref): \(error.localizedDescription)")
                #endif
                retryAfter[ref] = Date().addingTimeInterval(Self.openRetryDelay)
                lastOpenError = "\(ref): \(error.localizedDescription)"
                scheduleReconcile(after: .seconds(Self.openRetryDelay + 0.5))
            }
            inFlight.remove(ref)
        }
    }

    /// Moves a new mirror next to its device's other mirrors in the same
    /// window, in the remote's sort order (only relative to those siblings).
    private func placeAmongSiblings(_ workspace: Workspace, ref: SupermuxRemoteWorkspaceRef) {
        guard let manager = workspace.owningTabManager,
              let sortIndex = devices.record(for: ref)?.sortIndex else { return }
        let siblings = manager.tabs.compactMap { tab -> (id: UUID, sortIndex: Int)? in
            guard tab.id != workspace.id, index.isDeviceMirror(tab), let siblingRef = index.ref(forLocal: tab),
                  siblingRef.machineID == ref.machineID,
                  let siblingSort = devices.record(for: siblingRef)?.sortIndex else { return nil }
            return (tab.id, siblingSort)
        }
        let byRemoteOrder: ((id: UUID, sortIndex: Int), (id: UUID, sortIndex: Int)) -> Bool = { $0.sortIndex < $1.sortIndex }
        if let next = siblings.filter({ $0.sortIndex > sortIndex }).min(by: byRemoteOrder) {
            manager.reorderWorkspace(tabId: workspace.id, before: next.id)
        } else if let previous = siblings.filter({ $0.sortIndex < sortIndex }).max(by: byRemoteOrder) {
            manager.reorderWorkspace(tabId: workspace.id, after: previous.id)
        }
    }

    // MARK: - Readiness

    /// Ready once the startup session restore finished and the app is not quitting.
    static func appIsReady() -> Bool {
        guard let app = AppDelegate.shared else { return false }
        return app.didCompleteInitialSessionRestore && !app.isTerminatingApp
    }
}

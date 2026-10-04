import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit

/// Keeps exactly one local mirror workspace for every workspace on every
/// connected device (setting ``SupermuxDevicesSettings/autoMirror``, off
/// while this Mac is in Remote Host Mode), closes mirrors whose remote
/// workspace is gone, replaces orphaned mirrors, and drives the mirror
/// status projection.
///
/// Decisions come from the pure ``SupermuxMirrorReconciler``; this type
/// gathers its input (devices, records, mirrors, hidden set, in-flight opens)
/// and executes the plan:
/// - opens go through ``SupermuxDeviceWorkspaceOpener/openMirror(of:in:focus:createStarterTerminalIfEmpty:)``
///   one at a time, never focused, into the main window that already holds
///   that device's mirrors (else the preferred main window; never a new
///   window), then placed in the remote's order among its siblings;
/// - closes are local only, never prompt and never close anything remotely
///   (``SupermuxDeviceMirrorCloser/closeForCoordinator(_:)``); a duplicate's
///   close first hands the binding to the mirror that survives (the one
///   selected in its window, else one the user opened or restored rather
///   than auto-mirror's background copy).
///
/// Nothing runs until the startup session restore finished, so restored
/// placeholder mirrors (bound by `stableId`, or still holding pending restored
/// projections) always count as showing their workspace; stale bindings are
/// pruned once, right after that point.
///
/// A headless host does not mirror the Macs that view it: in Remote Host
/// Mode auto-mirror counts as off, so no new mirror opens there while the
/// mirrors already open stay (and still close when their remote workspace
/// closes). Turning the mode off brings auto-mirror back.
///
/// Passes are debounced (``debounce`` after the last trigger, at most
/// ``debounceMaxWait`` after the first), and a pass whose input matches the
/// last one after a plan with nothing to do skips planning.
@MainActor
final class SupermuxDeviceMirrorCoordinator {
    /// Trailing debounce for reconcile triggers (catalog churn arrives in bursts)…
    nonisolated static let debounce: Duration = .milliseconds(300)
    /// …capped, so a steady stream of triggers still gets a pass this often.
    nonisolated static let debounceMaxWait: Duration = .seconds(1)
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
    /// The armed wake-up and when it fires.
    private var scheduled: Task<Void, Never>?
    private var scheduledDeadline: ContinuousClock.Instant?
    /// The debounced pass and the first trigger of its burst.
    private var debouncedDeadline: ContinuousClock.Instant?
    private var burstStart: ContinuousClock.Instant?
    /// The earliest pass asked for at a set time (a follow-up, an open
    /// retry, the session-restore wait); triggers never postpone it.
    private var dueDeadline: ContinuousClock.Instant?
    private var observers: [any NSObjectProtocol] = []
    private var eventsTask: Task<Void, Never>?
    private var revisionTask: Task<Void, Never>?
    private var openQueue: [SupermuxRemoteWorkspaceRef] = []
    private var openTask: Task<Void, Never>?
    private var inFlight: Set<SupermuxRemoteWorkspaceRef> = []
    private var retryAfter: [SupermuxRemoteWorkspaceRef: Date] = [:]
    /// Local mirrors auto-mirror opened in this session: background copies,
    /// which lose a duplicate tie to a mirror the user opened or restored.
    private var autoOpened: Set<UUID> = []
    private var didPruneBindings = false
    private var lastAutoMirror: Bool?
    /// The input of the last pass that planned.
    private var lastFingerprint: InputFingerprint?
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
            for await event in devices.events() {
                // Pokes are for their own consumers (those that can change
                // records bump the revision); link edges change authority.
                if case .topic = event { continue }
                self?.scheduleReconcile()
            }
        }
        revisionTask = Task { @MainActor [weak self, devices] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = devices.revision
                        // An unbound mirror that got a local pane stops being one.
                        _ = devices.localCatalogRevision
                    } onChange: { continuation.resume() }
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

    /// Runs a reconcile pass once triggers settle: ``debounce`` after the
    /// last one, but no later than ``debounceMaxWait`` after the first.
    func scheduleReconcile() {
        let now = ContinuousClock.now
        let start = burstStart ?? now
        burstStart = start
        debouncedDeadline = min(now + Self.debounce, start + Self.debounceMaxWait)
        armWakeUp()
    }

    /// Runs a reconcile pass no later than `delay` from now (a follow-up, an
    /// open retry, the session-restore wait): the earliest such deadline wins,
    /// and a sooner trigger still runs sooner.
    func scheduleReconcile(after delay: Duration) {
        let deadline = ContinuousClock.now + delay
        if let due = dueDeadline, due <= deadline { return }
        dueDeadline = deadline
        armWakeUp()
    }

    /// Runs a full pass now, planning and projecting even when nothing
    /// changed (tests and the `supermux.devices.reconcile` socket method).
    func reconcileNow() {
        clearSchedule()
        reconcile(force: true)
    }

    private var nextDeadline: ContinuousClock.Instant? {
        [debouncedDeadline, dueDeadline].compactMap { $0 }.min()
    }

    /// Arms one wake-up for the next deadline. A debounce that moves later
    /// keeps the armed wake-up, which re-arms when it fires early.
    private func armWakeUp() {
        guard let deadline = nextDeadline else { return }
        if let armed = scheduledDeadline, armed <= deadline { return }
        scheduled?.cancel()
        scheduledDeadline = deadline
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.wakeUp()
        }
    }

    private func wakeUp() {
        scheduled = nil
        scheduledDeadline = nil
        guard let deadline = nextDeadline else { return }
        if deadline > ContinuousClock.now {
            armWakeUp()
            return
        }
        clearSchedule()
        reconcile()
    }

    private func clearSchedule() {
        scheduled?.cancel()
        scheduled = nil
        scheduledDeadline = nil
        debouncedDeadline = nil
        burstStart = nil
        dueDeadline = nil
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
    /// caller), backing off, whose close on their Mac is pending, or whose
    /// mirror's last terminal is being closed.
    var busyRefs: Set<SupermuxRemoteWorkspaceRef> {
        let now = Date()
        let backingOff = retryAfter.filter { $0.value > now }.keys
        return inFlight.union(openQueue).union(backingOff)
            .union(opener.openingRefs)
            .union(closer.pendingRemoteCloses)
            .union(closer.lastTerminalClosesInFlight)
    }

    /// Auto-mirror as passes apply it: the setting, except on a Mac in Remote
    /// Host Mode (a headless host has no one to show the other Macs to).
    var effectiveAutoMirror: Bool {
        settings.autoMirror && !SupermuxRemoteHostMode.isEnabled()
    }

    private func handle(_ note: Notification) {
        if note.name == UserDefaults.didChangeNotification {
            // Any defaults write lands here; only react to auto-mirror as
            // applied (the setting, or Remote Host Mode turning on or off).
            let autoMirror = effectiveAutoMirror
            guard autoMirror != lastAutoMirror else { return }
            lastAutoMirror = autoMirror
        }
        scheduleReconcile()
    }

    // MARK: - Reconcile

    private func reconcile(force: Bool = false) {
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
        // Closes the user made while a Mac was offline go out once it is back.
        closer.sendPendingCloses()
        let input = makeInput()
        lastAutoMirror = input.autoMirror
        let fingerprint = InputFingerprint(input)
        // The same input after a plan with nothing to open, close, unhide or
        // confirm plans nothing again.
        if force || fingerprint != lastFingerprint || lastPlan != SupermuxMirrorReconciler.Plan() {
            lastFingerprint = fingerprint
            execute(reconciler.plan(input))
        }
        projector.refresh(force: force)
        if let followUp = lastPlan.followUpAfter {
            scheduleReconcile(after: .milliseconds(Int(followUp * 1000)))
        }
        if let retry = nextRetryDelay() {
            scheduleReconcile(after: retry)
        }
    }

    private func execute(_ plan: SupermuxMirrorReconciler.Plan) {
        reconcileCount += 1
        lastPlan = plan
        // Before the closes: the survivor must hold the binding when the
        // bound copy goes (its close unbinds only its own stable id).
        for rebind in plan.rebinds {
            guard let workspace = Workspace.liveWorkspace(id: rebind.localWorkspaceID) else { continue }
            index.handOver(rebind.ref, to: workspace)
        }
        for close in plan.closes {
            guard let workspace = Workspace.liveWorkspace(id: close.localWorkspaceID) else { continue }
            #if DEBUG
            cmuxDebugLog("supermux.autoMirror close \(close.ref) local=\(close.localWorkspaceID) reason=\(close.reason.rawValue)")
            #endif
            closer.closeForCoordinator(workspace)
        }
        if !plan.unhide.isEmpty { hidden.remove(plan.unhide) }
        enqueueOpens(plan.opens)
    }

    /// How long until the earliest backing-off ref may be opened again (nil
    /// when none is backing off). Every pass re-arms this, so a retry is never
    /// lost when a sooner pass replaced the pending one.
    private func nextRetryDelay() -> Duration? {
        let now = Date()
        retryAfter = retryAfter.filter { $0.value > now }
        guard let next = retryAfter.values.min() else { return nil }
        return .milliseconds(Int((next.timeIntervalSince(now) + 0.05) * 1000))
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
        let liveMirrors = index.mirrors()
        autoOpened.formIntersection(liveMirrors.map(\.workspace.id))
        let mirrors = liveMirrors.map { mirror in
            SupermuxMirrorReconciler.Mirror(
                ref: mirror.ref,
                localWorkspaceID: mirror.workspace.id,
                isBound: mirror.isBound,
                isProjected: catalog.projectionMachines(forWorkspace: mirror.workspace.id).contains(mirror.ref.machine),
                isSelected: mirror.workspace.owningTabManager?.selectedTabId == mirror.workspace.id,
                isAutoOpened: autoOpened.contains(mirror.workspace.id)
            )
        }
        return SupermuxMirrorReconciler.Input(
            autoMirror: effectiveAutoMirror,
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
            guard effectiveAutoMirror, !hidden.contains(ref), index.localWorkspace(showing: ref) == nil,
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
                if !opened.reused {
                    autoOpened.insert(opened.workspace.id)
                    placeAmongSiblings(opened.workspace, ref: ref)
                }
                #if DEBUG
                cmuxDebugLog("supermux.autoMirror open \(ref) local=\(opened.workspace.id) reused=\(opened.reused)")
                #endif
                retryAfter[ref] = nil
                lastOpenError = nil
            } catch {
                #if DEBUG
                cmuxDebugLog("supermux.autoMirror open failed \(ref): \(error.localizedDescription)")
                #endif
                // The pass after this drain re-arms a reconcile for the retry.
                retryAfter[ref] = Date().addingTimeInterval(Self.openRetryDelay)
                lastOpenError = "\(ref): \(error.localizedDescription)"
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

    // MARK: - Input fingerprint

    /// A pass's input without its clock, which matters only while the last
    /// plan still waits on a suspicion (it then has a follow-up and the next
    /// pass plans anyway).
    private struct InputFingerprint: Equatable {
        let autoMirror: Bool
        let devices: [SupermuxMirrorReconciler.Device]
        let mirrors: [SupermuxMirrorReconciler.Mirror]
        let hidden: Set<SupermuxRemoteWorkspaceRef>
        let busy: Set<SupermuxRemoteWorkspaceRef>

        init(_ input: SupermuxMirrorReconciler.Input) {
            autoMirror = input.autoMirror
            devices = input.devices
            mirrors = input.mirrors
            hidden = input.hidden
            busy = input.busy
        }
    }

    // MARK: - Readiness

    /// Ready once the startup session restore finished and the app is not quitting.
    static func appIsReady() -> Bool {
        guard let app = AppDelegate.shared else { return false }
        return app.didCompleteInitialSessionRestore && !app.isTerminatingApp
    }
}

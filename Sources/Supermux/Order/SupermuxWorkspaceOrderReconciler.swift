import AppKit
import Combine
import Foundation
import Observation
import SupermuxKit
import SupermuxMobileCore

/// Keeps every window's workspace order in the shared order, with no
/// upstream hook: on the Mac that owns a workspace its tab position is the
/// truth (capture writes the key), and on every other Mac its mirror is
/// placed where that key says (apply moves only mirrors, never writes a key).
///
/// A pass for one window runs on the next main turn after any of its tabs or
/// groups change (`tabsPublisher` emits during `willSet`), after a device
/// record changes, and after the outbox's held keys change. It waits while
/// the app is not ready (session restore, quitting) or a mouse button is
/// down, re-arming every 300 ms, and does nothing unless the DEBUG mode is
/// ``SupermuxOrderDebugMode/normal``. A pass:
///
/// 1. captures: ``SupermuxOrderCapture`` diffs the tabs against the order the
///    last pass left, attributing moves to the rows `workspaceOrderDidChange`
///    named (hints), and writes new own keys to the store (then ticks state
///    sync) and sends moved mirrors' keys to their owners (the outbox);
/// 2. applies: ``SupermuxOrderArrangement`` places each keyed, ungrouped
///    mirror at a unit boundary and the window is reordered once
///    (`isApplying` keeps its own order change from counting as a hint);
/// 3. records the resulting order as the next baseline, so apply's moves are
///    never captured as user moves.
///
/// A fork reorder that is not the user's (sibling placement, a mirrored pin)
/// runs inside ``programmatic(moving:in:_:)``: no hint, weight 0, never re-keyed.
@MainActor
final class SupermuxWorkspaceOrderReconciler {
    /// How long a gated pass waits before trying again.
    static let rearmDelay: Duration = .milliseconds(300)

    private struct WindowState {
        var baseline: [SupermuxOrderPosition<UUID>]?
        var lastAttempted: [UUID]?
        var signature: [SupermuxWorkspaceOrderRow]?
        var hints: Set<UUID> = []
        var programmatic: Set<UUID> = []
    }

    /// What the reconciler did since launch (DEBUG `order_state`).
    private(set) var counters = SupermuxWorkspaceOrderCounters()
    /// This Mac's origin: the seed of a first key when nothing is known.
    let origin: String

    private let store: SupermuxWorkspaceOrderStore
    private let devices: SupermuxDevices
    private let index: SupermuxDeviceWorkspaceIndex
    private let outbox: SupermuxMirrorOrderOutbox
    private let tabManagers: @MainActor () -> [TabManager]
    private let isReady: @MainActor () -> Bool
    private let requestSyncTick: @MainActor () -> Void
    private let capture = SupermuxOrderCapture()
    private let arrangement = SupermuxOrderArrangement()
    private let orderKey = SupermuxOrderKey()

    private var windows: [ObjectIdentifier: WindowState] = [:]
    private var subscriptions: [ObjectIdentifier: [AnyCancellable]] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var revisionTask: Task<Void, Never>?
    private var scheduled: Set<ObjectIdentifier> = []
    private var passTask: Task<Void, Never>?
    private var isApplying = false
    private var didPrune = false

    init(
        store: SupermuxWorkspaceOrderStore,
        devices: SupermuxDevices,
        index: SupermuxDeviceWorkspaceIndex,
        outbox: SupermuxMirrorOrderOutbox,
        origin: String,
        tabManagers: @escaping @MainActor () -> [TabManager] = SupermuxMobileSidebarStatusObserver.allTabManagers,
        isReady: @escaping @MainActor () -> Bool = SupermuxDeviceMirrorCoordinator.appIsReady,
        requestSyncTick: @escaping @MainActor () -> Void = { SupermuxStateSyncTicker.shared.request() }
    ) {
        self.store = store
        self.devices = devices
        self.index = index
        self.outbox = outbox
        self.origin = origin
        self.tabManagers = tabManagers
        self.isReady = isReady
        self.requestSyncTick = requestSyncTick
    }

    // MARK: - Lifecycle

    /// Starts following windows, reorders and device records. Idempotent.
    func start() {
        guard revisionTask == nil else { return }
        outbox.onChange = { [weak self] in self?.scheduleAll() }
        // Synchronous, inside the post: the hint must be recorded before the
        // tab change's pass runs, and apply's own post must see `isApplying`.
        observers.append(NotificationCenter.default.addObserver(
            forName: .workspaceOrderDidChange, object: nil, queue: nil
        ) { [weak self] note in
            let manager = note.object as? TabManager
            let moved = note.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
            MainActor.assumeIsolated {
                guard let manager else { return }
                self?.noteMoved(moved, in: manager)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachWindows() }
        })
        revisionTask = Task { @MainActor [weak self, devices] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = devices.revision } onChange: { continuation.resume() }
                }
                self?.scheduleAll()
            }
        }
        attachWindows()
    }

    /// Switches the DEBUG mode. Back to normal, every window starts over from
    /// its tabs and the records (as on the first pass after launch).
    func setMode(_ mode: SupermuxOrderDebugMode) {
        #if DEBUG
        SupermuxOrderDebugMode.current = mode
        #endif
        windows.removeAll()
        outbox.reset()
        requestSyncTick()
        scheduleAll()
    }

    // MARK: - Entry points

    /// Runs `body`, a reorder the fork makes on its own (not the user's),
    /// so the moved row is never re-keyed or sent to its owner.
    /// - Parameters:
    ///   - workspaceID: The row `body` moves.
    ///   - manager: The window it moves in.
    ///   - body: The reorder.
    func programmatic<T>(moving workspaceID: UUID, in manager: TabManager, _ body: () -> T) -> T {
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        windows[ObjectIdentifier(manager), default: WindowState()].programmatic.insert(workspaceID)
        schedule(manager)
        return body()
    }

    /// Writes an own row's key and moves the row where it now sorts among the
    /// window's other rows (a normal, clamped reorder), then captures at once,
    /// ignoring the mouse gate: the owner's side of `set_order`.
    /// - Parameters:
    ///   - workspace: The own workspace.
    ///   - key: Its requested key (valid).
    ///   - manager: Its window.
    /// - Returns: The key the workspace holds afterwards (re-keyed where a pin
    ///   or group clamped it).
    func moveOwnRow(_ workspace: Workspace, toKey key: String, in manager: TabManager) -> String? {
        let previousKey = store.key(forStableID: workspace.stableId)
        writeOwnKeys([workspace.id: key], stableIDs: [workspace.id: workspace.stableId])
        let rows = makeRows(manager)
        let items = rows.rows.map { row in
            row.id == workspace.id ? row.applyItem(fixed: false, unit: row.id.uuidString) : row.applyItem(fixed: true)
        }
        let target = arrangement.arrange(items).firstIndex(of: workspace.id)
        if let target, target != manager.tabs.firstIndex(where: { $0.id == workspace.id }) {
            manager.reorderWorkspace(tabId: workspace.id, toIndex: target)
        }
        // A pin or group clamp kept the row elsewhere, so the requested key
        // does not say where it sits: it takes its old key back, and capture
        // re-keys it where it landed when that key no longer fits there.
        if manager.tabs.firstIndex(where: { $0.id == workspace.id }) != target {
            if let previousKey {
                store.setKey(previousKey, forStableID: workspace.stableId)
            } else {
                store.removeKey(forStableID: workspace.stableId)
            }
        }
        if SupermuxOrderDebugMode.current.reconciles {
            reconcile(manager)
        }
        requestSyncTick()
        return store.key(forStableID: workspace.stableId)
    }

    /// Counts one `set_order` this Mac served (`refused`: answered with an error).
    func countSetOrder(refused: Bool) {
        counters.setOrderReceived += 1
        if refused { counters.setOrderRefused += 1 }
    }

    /// Every valid key this Mac knows: its store, every device record, every held key.
    func knownKeys() -> [String] {
        let recordKeys = devices.devices.flatMap { device in
            devices.records(on: device.machine).compactMap(\.supermuxOrderKey)
        }
        return Array(Set((Array(store.keys.values) + recordKeys + outbox.pendingKeys).filter(orderKey.isValid)))
    }

    /// One window's rows as the next pass would see them.
    func makeRows(_ manager: TabManager) -> SupermuxWorkspaceOrderRows {
        SupermuxWorkspaceOrderRows(manager: manager, store: store, index: index, devices: devices, outbox: outbox)
    }

    // MARK: - Triggers

    private func attachWindows() {
        let managers = tabManagers()
        let live = Set(managers.map(ObjectIdentifier.init))
        subscriptions = subscriptions.filter { live.contains($0.key) }
        windows = windows.filter { live.contains($0.key) }
        for manager in managers where subscriptions[ObjectIdentifier(manager)] == nil {
            subscriptions[ObjectIdentifier(manager)] = [
                manager.tabsPublisher.sink { [weak self, weak manager] _ in
                    guard let manager else { return }
                    self?.schedule(manager)
                },
                manager.workspaceGroupsPublisher.sink { [weak self, weak manager] _ in
                    guard let manager else { return }
                    self?.schedule(manager)
                },
            ]
        }
    }

    private func noteMoved(_ ids: [UUID], in manager: TabManager) {
        guard !isApplying, SupermuxOrderDebugMode.current.reconciles else { return }
        windows[ObjectIdentifier(manager), default: WindowState()].hints.formUnion(ids)
        schedule(manager)
    }

    private func schedule(_ manager: TabManager) {
        scheduled.insert(ObjectIdentifier(manager))
        armPass(after: nil)
    }

    private func scheduleAll() {
        scheduled.formUnion(tabManagers().map(ObjectIdentifier.init))
        armPass(after: nil)
    }

    private func armPass(after delay: Duration?) {
        guard passTask == nil else { return }
        passTask = Task { @MainActor [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            guard let self else { return }
            self.passTask = nil
            self.runScheduledPasses()
        }
    }

    private func runScheduledPasses() {
        guard SupermuxOrderDebugMode.current.reconciles else {
            scheduled.removeAll()
            return
        }
        guard isReady(), NSEvent.pressedMouseButtons == 0 else {
            armPass(after: Self.rearmDelay)
            return
        }
        let due = scheduled
        scheduled.removeAll()
        for manager in tabManagers() where due.contains(ObjectIdentifier(manager)) {
            reconcile(manager)
        }
    }

    // MARK: - The pass

    private func reconcile(_ manager: TabManager) {
        counters.passes += 1
        pruneStoreIfNeeded()
        outbox.settle { [devices] ref in devices.record(for: ref)?.supermuxOrderKey }
        let windowKey = ObjectIdentifier(manager)
        var state = windows[windowKey] ?? WindowState()
        let rows = makeRows(manager)
        if rows.rows == state.signature, state.hints.isEmpty, state.programmatic.isEmpty { return }

        let plan = capture.plan(
            baseline: state.baseline,
            rows: rows.captureRows,
            hinted: state.hints,
            programmatic: state.programmatic,
            known: knownKeys(),
            seed: origin
        )
        if !plan.ownKeys.isEmpty {
            let stableIDs = Dictionary(uniqueKeysWithValues: rows.rows.map { ($0.id, $0.stableID) })
            writeOwnKeys(plan.ownKeys, stableIDs: stableIDs)
            requestSyncTick()
        }
        for (id, key) in plan.mirrorKeys {
            guard let row = rows.row(id), let ref = row.ref else { continue }
            outbox.send(key, isPinned: row.isPinned, for: ref)
        }

        let desired = arrangement.arrange(makeRows(manager).applyItems)
        if desired != manager.tabs.map(\.id), desired != state.lastAttempted {
            isApplying = true
            if case .success = manager.reorderWorkspaces(orderedWorkspaceIds: desired) {
                counters.applies += 1
            }
            isApplying = false
            // An order pins or groups would not take is not issued again.
            state.lastAttempted = manager.tabs.map(\.id) == desired ? nil : desired
        }

        let final = makeRows(manager)
        state.baseline = final.captureRows.map(\.position)
        state.signature = final.rows
        state.hints = []
        state.programmatic = []
        windows[windowKey] = state
    }

    private func writeOwnKeys(_ keys: [UUID: String], stableIDs: [UUID: UUID]) {
        var byStableID: [UUID: String] = [:]
        var written: [UUID] = []
        for (id, key) in keys {
            guard let stableID = stableIDs[id], orderKey.isValid(key), store.key(forStableID: stableID) != key else { continue }
            byStableID[stableID] = key
            written.append(id)
        }
        guard !byStableID.isEmpty else { return }
        store.setKeys(byStableID)
        counters.recordWrites(written)
    }

    /// Drops the keys of closed workspaces once the restore is done, and
    /// again whenever the store outgrows its capacity.
    private func pruneStoreIfNeeded() {
        guard !didPrune || store.isOverCapacity else { return }
        didPrune = true
        let own = tabManagers().flatMap(\.tabs).filter { !index.isDeviceMirror($0) }
        store.prune(keepingStableIDs: Set(own.map(\.stableId)))
    }
}

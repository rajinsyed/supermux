import Combine
import Foundation
import SupermuxKit

/// Re-emits the EXISTING `workspace.updated` topic when the supermux-only
/// inputs of the mobile workspace-list payload change: agent activity
/// (`supermux_activity`, with the working tabs and the lifecycle pills it
/// dedupes) and workspace→project association (`supermux_project_id`).
///
/// Upstream's `MobileWorkspaceListObserver` hash-diffs only the fields it
/// knows about (its `summaryHash` is deliberately untouched per architecture
/// §5/§8), so an activity or association mutation alone would never poke the
/// phone. This observer covers exactly that gap:
///
/// - **Activity** — ``SupermuxWorkspaceLifecycleRelay`` fires on every agent
///   lifecycle set/clear that changed a value (the single choke point in
///   `Workspace.recordAgentLifecycleChange`; a hook re-reporting an unchanged
///   phase does not fire it). The pass re-signs each relayed workspace
///   (``activitySignature(of:)``: everything the exported record derives from
///   the lifecycle) and counts only a changed signature. Device mirrors are
///   skipped: the export filter never sends them, so a mirror's overlay
///   update reaches no phone or Mac.
/// - **Association** — the resolution inputs of
///   ``SupermuxWorkspaceAssociationStore/projectId(forWorkspace:directory:in:)``
///   are Observation-tracked: the store's `revision`, the durable directory
///   map, and the projects list. A summary-hash diff suppresses no-op churn.
///
/// Changes are coalesced through one trailing 80 ms pass (the same throttle
/// window as `MobileWorkspaceListObserver` and the projects observer). The
/// payload is `[:]` — `workspace.updated` is a payload-light poke and the
/// phone refetches `workspace.list`, exactly as for upstream's own emits. It
/// goes out at most once per ``emitInterval`` (the first change at once, later
/// ones in one trailing emit), so an agent burst never costs a phone one full
/// list refetch per hook.
///
/// Since cmux 0.64.21 the phone prefers **mobile state sync v2**: once it has
/// negotiated `mobile.sync.fetch`, `MobileShellComposite` ignores the
/// `workspace.updated` poke entirely and only applies `mobile.sync.delta`
/// frames, as other Macs' `DeviceLink`s do. So every change also ticks the
/// shared ``SupermuxStateSyncTicker`` at once (the pass already waited its
/// window) — otherwise a v2 phone would never see an activity flip or an
/// association change, because upstream's `summaryHash` is blind to the fork
/// fields and nothing else would trip a delta.
///
/// Nothing runs while neither topic has a subscriber. The association
/// tracking lapses meanwhile, so the first subscriber gets one forced pass,
/// which emits and re-arms it. Every path that finds no subscriber suspends
/// the observer, so a brief resubscribe dip the subscription notifications
/// never see still gets that pass.
@MainActor
final class SupermuxMobileActivityObserver {
    /// Throttle window, mirroring `MobileWorkspaceListObserver`.
    static let throttle: Duration = .milliseconds(80)
    /// Timer slack for the pass and the trailing emit.
    static let tolerance: Duration = .milliseconds(40)
    /// The shortest gap between two `workspace.updated` emits.
    static let emitInterval: Duration = .seconds(1)

    private let projectsModel: SupermuxProjectsModel
    private let associations: SupermuxWorkspaceAssociationStore
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private let pokeStateSync: @MainActor () -> Void
    private let hasSubscribers: @MainActor () -> Bool
    private var lifecycleCancellable: AnyCancellable?
    private var subscriptionsObserver: NSObjectProtocol?
    /// Set by ``suspend()`` when a path finds no subscriber: work and
    /// signatures were dropped and association tracking may have lapsed, so
    /// the next subscriber gets one forced pass.
    private var isSuspended = true
    /// The scheduled trailing pass; `nil` when idle. Its presence is the
    /// throttle: at most one change check per window.
    private var pendingPass: Task<Void, Never>?
    /// Whether the pending pass emits unconditionally (the first subscriber
    /// arrived) instead of diffing.
    private var pendingForce = false
    /// Workspaces the lifecycle relay reported since the last pass.
    private var pendingWorkspaceIDs: Set<UUID> = []
    /// Each exported workspace's ``activitySignature(of:)`` at its last pass.
    private var lastSignatureByWorkspaceID: [UUID: Int] = [:]
    private var lastAssociationHash = 0
    /// The trailing `workspace.updated` emit; `nil` when none is waiting.
    private var pendingEmit: Task<Void, Never>?
    private var lastEmitAt: ContinuousClock.Instant?

    /// Creates the observer. No initial emit: a freshly-connected phone
    /// fetches `workspace.list` itself; this observer only signals changes.
    ///
    /// - Parameters:
    ///   - projectsModel: The app-wide projects model (association resolution
    ///     depends on the registered projects).
    ///   - associations: The app-wide workspace→project association store.
    ///   - lifecycleEvents: Agent-lifecycle mutation stream; defaults to
    ///     ``SupermuxWorkspaceLifecycleRelay``.
    ///   - emit: The event sink; defaults to `MobileHostService.emitEvent`.
    ///   - pokeStateSync: The mobile state sync v2 tick; defaults to
    ///     ``SupermuxStateSyncTicker/requestNow()``, which also absorbs a
    ///     pending sidebar-status request and no-ops unless a client
    ///     subscribed to the delta topic.
    ///   - hasSubscribers: Whether `workspace.updated` or the delta topic has
    ///     a subscriber.
    init(
        projectsModel: SupermuxProjectsModel,
        associations: SupermuxWorkspaceAssociationStore,
        lifecycleEvents: AnyPublisher<UUID, Never>? = nil,
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        },
        pokeStateSync: @escaping @MainActor () -> Void = {
            SupermuxStateSyncTicker.shared.requestNow()
        },
        hasSubscribers: @escaping @MainActor () -> Bool = {
            MobileHostService.hasEventSubscribers(topic: "workspace.updated")
                || MobileHostService.hasEventSubscribers(topic: MobileStateSyncHost.deltaTopic)
        }
    ) {
        self.projectsModel = projectsModel
        self.associations = associations
        self.emit = emit
        self.pokeStateSync = pokeStateSync
        self.hasSubscribers = hasSubscribers
        lastAssociationHash = armAndReadAssociationHash()
        isSuspended = !hasSubscribers()
        // Resolved here rather than as a default argument: default-argument
        // expressions evaluate in the caller's context, where touching the
        // @MainActor relay warns under strict concurrency.
        let events = lifecycleEvents
            ?? SupermuxWorkspaceLifecycleRelay.lifecycleDidChange.eraseToAnyPublisher()
        lifecycleCancellable = events.sink { [weak self] workspaceID in
            self?.lifecycleDidChange(workspaceID)
        }
        subscriptionsObserver = NotificationCenter.default.addObserver(
            forName: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.subscriptionsDidChange() }
        }
    }

    deinit {
        pendingPass?.cancel()
        pendingEmit?.cancel()
        if let subscriptionsObserver {
            NotificationCenter.default.removeObserver(subscriptionsObserver)
        }
    }

    private func lifecycleDidChange(_ workspaceID: UUID) {
        guard hasSubscribers() else {
            suspend()
            return
        }
        pendingWorkspaceIDs.insert(workspaceID)
        schedulePass(force: false)
    }

    /// The first subscriber after a suspension gets one forced pass; with no
    /// subscriber left, the observer suspends.
    private func subscriptionsDidChange() {
        guard hasSubscribers() else {
            suspend()
            return
        }
        guard isSuspended else { return }
        isSuspended = false
        schedulePass(force: true)
    }

    /// Drops pending work and signatures while nobody subscribes. A dropped
    /// relay or association change leaves them stale, so every path that
    /// finds no subscriber calls this, and the next subscriber's forced pass
    /// re-arms association tracking.
    private func suspend() {
        pendingPass?.cancel()
        pendingPass = nil
        pendingForce = false
        pendingEmit?.cancel()
        pendingEmit = nil
        pendingWorkspaceIDs = []
        lastSignatureByWorkspaceID = [:]
        isSuspended = true
    }

    /// Schedules the trailing pass unless one is already pending; a forced
    /// request upgrades a pending diffing pass to an unconditional emit.
    private func schedulePass(force: Bool) {
        guard hasSubscribers() else {
            suspend()
            return
        }
        pendingForce = pendingForce || force
        guard pendingPass == nil else { return }
        pendingPass = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.throttle, tolerance: Self.tolerance)
            guard let self, !Task.isCancelled else { return }
            self.pendingPass = nil
            self.runPass()
        }
    }

    private func runPass() {
        let force = pendingForce
        pendingForce = false
        let hash = armAndReadAssociationHash()
        let associationChanged = hash != lastAssociationHash
        lastAssociationHash = hash
        let activityChanged = resignPendingWorkspaces()
        guard force || associationChanged || activityChanged else { return }
        requestWorkspaceUpdatedEmit()
        // v1 phones act on the poke above; v2 phones and other Macs ignore it
        // and only apply delta frames, so rebuild the sync store too.
        pokeStateSync()
    }

    /// Re-signs the workspaces the relay reported; true when any exported
    /// workspace's signature changed. A closed workspace or a device mirror
    /// drops its signature, so a workspace that stops being a mirror counts
    /// as changed on its next relay.
    private func resignPendingWorkspaces() -> Bool {
        let workspaceIDs = pendingWorkspaceIDs
        pendingWorkspaceIDs = []
        var changed = false
        var signedNewWorkspace = false
        for workspaceID in workspaceIDs {
            guard let workspace = Workspace.liveWorkspace(id: workspaceID),
                  !SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) else {
                lastSignatureByWorkspaceID[workspaceID] = nil
                continue
            }
            let signature = Self.activitySignature(of: workspace)
            let previous = lastSignatureByWorkspaceID.updateValue(signature, forKey: workspaceID)
            if previous != signature {
                changed = true
            }
            if previous == nil {
                signedNewWorkspace = true
            }
        }
        if signedNewWorkspace {
            pruneClosedWorkspaces()
        }
        return changed
    }

    /// Drops the signatures of workspaces that closed without a later relay.
    /// The map only grows when a pass signs a new workspace, so pruning then
    /// keeps it bounded by the open workspaces without a sweep on every hook.
    /// Dropping a signature is always safe: a missing one counts as changed.
    private func pruneClosedWorkspaces() {
        lastSignatureByWorkspaceID = lastSignatureByWorkspaceID.filter { workspaceID, _ in
            Workspace.liveWorkspace(id: workspaceID) != nil
        }
    }

    /// Emits `workspace.updated` now when the last emit is at least
    /// ``emitInterval`` old, otherwise once when it will be. A request made
    /// while that emit waits joins it.
    private func requestWorkspaceUpdatedEmit() {
        guard pendingEmit == nil else { return }
        let wait = lastEmitAt.map { ContinuousClock.now.duration(to: $0 + Self.emitInterval) } ?? .zero
        guard wait > .zero else {
            emitWorkspaceUpdated()
            return
        }
        pendingEmit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait, tolerance: Self.tolerance)
            guard let self, !Task.isCancelled else { return }
            self.pendingEmit = nil
            self.emitWorkspaceUpdated()
        }
    }

    private func emitWorkspaceUpdated() {
        lastEmitAt = .now
        emit("workspace.updated", [:])
    }

    /// Hash of everything the exported record derives from the agent
    /// lifecycle: `supermuxActivity`, the per-agent activity that decides
    /// which lifecycle pills `supermuxStatusEntries` drops, and
    /// `supermuxWorkingPanelIDs`.
    private static func activitySignature(of workspace: Workspace) -> Int {
        var hasher = Hasher()
        hasher.combine(SupermuxWorkspaceActivityResolver.activity(for: workspace))
        hasher.combine(SupermuxWorkspaceActivityResolver.activityByAgentKey(for: workspace))
        hasher.combine(workspace.supermuxWorkingPanelIDs())
        return hasher.finalize()
    }

    /// Reads the association summary hash, re-arming observation atomically
    /// with the read (the one-shot `onChange` is re-established by every
    /// pass, so tracking never goes dead while someone subscribes).
    private func armAndReadAssociationHash() -> Int {
        withObservationTracking {
            Self.associationSummaryHash(projects: projectsModel.projects, associations: associations)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePass(force: false)
            }
        }
    }

    /// Stable hash over every input of association resolution: the store's
    /// mutation `revision`, the durable directory→project map (which can
    /// change without a revision bump), and the full project records (root
    /// and worktrees-dir changes move directory matches).
    private static func associationSummaryHash(
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(associations.revision)
        hasher.combine(associations.durableDirectoryAssociations)
        hasher.combine(projects)
        return hasher.finalize()
    }
}

import Combine
import Foundation
import SupermuxKit

/// Re-emits the EXISTING `workspace.updated` topic when the supermux-only
/// inputs of the mobile workspace-list payload change: agent activity
/// (`supermux_activity`) and workspace→project association
/// (`supermux_project_id`).
///
/// Upstream's `MobileWorkspaceListObserver` hash-diffs only the fields it
/// knows about (its `summaryHash` is deliberately untouched per architecture
/// §5/§8), so an activity or association mutation alone would never poke the
/// phone. This observer covers exactly that gap:
///
/// - **Activity** — ``SupermuxWorkspaceLifecycleRelay`` fires on every agent
///   lifecycle set/clear (the single choke point in
///   `Workspace.recordAgentLifecycleChange`). Each relay event is a real
///   mutation, so it always schedules an emit (no re-hash is possible
///   without walking every window's tab list).
/// - **Association** — the resolution inputs of
///   ``SupermuxWorkspaceAssociationStore/projectId(forWorkspace:directory:in:)``
///   are Observation-tracked: the store's `revision`, the durable directory
///   map, and the projects list. A summary-hash diff suppresses no-op churn.
///
/// Emits are coalesced through one trailing 80 ms pass (the same throttle
/// window as `MobileWorkspaceListObserver` and the projects observer). The
/// payload is `[:]` — `workspace.updated` is a payload-light poke and the
/// phone refetches `workspace.list`, exactly as for upstream's own emits.
///
/// Since cmux 0.64.21 the phone prefers **mobile state sync v2**: once it has
/// negotiated `mobile.sync.fetch`, `MobileShellComposite` ignores the
/// `workspace.updated` poke entirely and only applies `mobile.sync.delta`
/// frames. So every pass also ticks `MobileStateSyncHost`, exactly as
/// upstream's `MobileWorkspaceListObserver` does — otherwise a v2 phone would
/// never see an activity flip or an association change, because upstream's
/// `summaryHash` is blind to the fork fields and nothing else would trip a
/// delta. The tick is a cheap no-op when no phone subscribed to the delta
/// topic.
@MainActor
final class SupermuxMobileActivityObserver {
    private let projectsModel: SupermuxProjectsModel
    private let associations: SupermuxWorkspaceAssociationStore
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private let pokeStateSync: @MainActor () -> Void
    private var lifecycleCancellable: AnyCancellable?
    /// The scheduled trailing pass; `nil` when idle. Its presence is the
    /// throttle: at most one emit-check per window.
    private var pendingPass: Task<Void, Never>?
    /// Whether the pending pass emits unconditionally (a lifecycle relay
    /// event — always a real mutation) instead of hash-diffing.
    private var pendingForce = false
    private var lastAssociationHash = 0
    /// Throttle window, mirroring `MobileWorkspaceListObserver`.
    private let throttleMilliseconds: Int = 80

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
    ///     `MobileStateSyncHost.broadcastIfSubscribed()`, which no-ops unless a
    ///     phone subscribed to the delta topic.
    init(
        projectsModel: SupermuxProjectsModel,
        associations: SupermuxWorkspaceAssociationStore,
        lifecycleEvents: AnyPublisher<UUID, Never>? = nil,
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        },
        pokeStateSync: @escaping @MainActor () -> Void = {
            MobileStateSyncHost.shared.broadcastIfSubscribed()
        }
    ) {
        self.projectsModel = projectsModel
        self.associations = associations
        self.emit = emit
        self.pokeStateSync = pokeStateSync
        lastAssociationHash = armAndReadAssociationHash()
        // Resolved here rather than as a default argument: default-argument
        // expressions evaluate in the caller's context, where touching the
        // @MainActor relay warns under strict concurrency.
        let events = lifecycleEvents
            ?? SupermuxWorkspaceLifecycleRelay.lifecycleDidChange.eraseToAnyPublisher()
        lifecycleCancellable = events.sink { [weak self] _ in
            self?.schedulePass(force: true)
        }
    }

    deinit {
        pendingPass?.cancel()
    }

    /// Schedules the trailing pass unless one is already pending; a forced
    /// request upgrades a pending hash-diff pass to an unconditional emit.
    private func schedulePass(force: Bool) {
        pendingForce = pendingForce || force
        guard pendingPass == nil else { return }
        pendingPass = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.throttleMilliseconds ?? 80) * 1_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingPass = nil
            let force = self.pendingForce
            self.pendingForce = false
            let hash = self.armAndReadAssociationHash()
            let changed = hash != self.lastAssociationHash
            self.lastAssociationHash = hash
            if force || changed {
                self.emit("workspace.updated", [:])
                // v1 phones act on the poke above; v2 phones ignore it and only
                // apply delta frames, so rebuild the sync store too.
                self.pokeStateSync()
            }
        }
    }

    /// Reads the association summary hash, re-arming observation atomically
    /// with the read (the one-shot `onChange` is re-established by every
    /// pass, so tracking never goes dead while the observer lives).
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

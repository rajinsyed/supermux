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
@MainActor
final class SupermuxMobileActivityObserver {
    private let projectsModel: SupermuxProjectsModel
    private let associations: SupermuxWorkspaceAssociationStore
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
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
    init(
        projectsModel: SupermuxProjectsModel,
        associations: SupermuxWorkspaceAssociationStore,
        lifecycleEvents: AnyPublisher<UUID, Never>? = nil,
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        }
    ) {
        self.projectsModel = projectsModel
        self.associations = associations
        self.emit = emit
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

import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Watches ``SupermuxProjectsModel`` and emits `supermux.projects.updated` to
/// subscribed mobile clients whenever the iOS-facing shape of the projects
/// document materially changes — the project records, the terminal presets
/// (same file, same topic), or the section collapse state (same pattern as
/// `MobileWorkspaceListObserver`: observe the source of truth, hash-diff,
/// throttle, emit a payload-light poke; the phone refetches via
/// `mobile.supermux.projects.list`). Because every write handler mutates the
/// model, this is the single emission path for mobile AND desktop edits —
/// handlers never emit ad hoc, so double-pokes are impossible.
///
/// The model is `@Observable`, so instead of Combine publishers this observer
/// re-arms `withObservationTracking` around one summary-hash read. A mutation
/// schedules a single trailing pass 80 ms out; every mutation inside that
/// window coalesces into the same pass, which re-reads, hash-diffs, emits at
/// most once, and re-arms.
@MainActor
final class SupermuxMobileProjectsObserver {
    private let model: SupermuxProjectsModel
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private var lastSummaryHash: Int = 0
    /// The scheduled trailing pass; `nil` when idle. Its presence is the
    /// throttle: at most one emit-check per window.
    private var pendingPass: Task<Void, Never>?
    /// Throttle window, mirroring `MobileWorkspaceListObserver`.
    private let throttleMilliseconds: Int = 80

    /// Creates the observer and emits the initial snapshot unconditionally so
    /// freshly-paired clients see current state without waiting for a mutation.
    ///
    /// - Parameters:
    ///   - model: The app-wide projects model to watch.
    ///   - emit: The event sink; defaults to `MobileHostService.emitEvent`.
    init(
        model: SupermuxProjectsModel,
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        }
    ) {
        self.model = model
        self.emit = emit
        emitIfNeededAndRearm(force: true)
    }

    deinit {
        pendingPass?.cancel()
    }

    /// Schedules the trailing emit pass unless one is already pending.
    private func modelDidChange() {
        guard pendingPass == nil else { return }
        pendingPass = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.throttleMilliseconds ?? 80) * 1_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingPass = nil
            self.emitIfNeededAndRearm(force: false)
        }
    }

    /// Reads the summary hash (re-arming observation atomically with the
    /// read), emits when it changed, and stores the new value.
    private func emitIfNeededAndRearm(force: Bool) {
        let hash = withObservationTracking {
            Self.summaryHash(
                projects: model.projects,
                presets: model.presets,
                isSectionCollapsed: model.isSectionCollapsed
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.modelDidChange()
            }
        }
        if !force, hash == lastSummaryHash {
            return
        }
        lastSummaryHash = hash
        emit(SupermuxMobileTopic.projectsUpdated.rawValue, [:])
    }

    /// Stable hash of the iOS-facing projection: the full project records (the
    /// DTO derives from every stored field), the terminal presets (they
    /// persist in the same projects file and ride the same topic), and the
    /// section collapse state.
    private static func summaryHash(
        projects: [SupermuxProject],
        presets: [SupermuxTerminalPreset],
        isSectionCollapsed: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(projects)
        hasher.combine(presets)
        hasher.combine(isSectionCollapsed)
        return hasher.finalize()
    }
}

/// Watches the worktree lists (``SupermuxProjectsModel/worktreesByProjectId``)
/// and the unopened-worktree PR badges
/// (``SupermuxWorktreePullRequestModel/pullRequestsByWorktreePath``) and emits
/// `supermux.worktrees.updated` when either materially changes — covering
/// create/remove from ANY entrypoint (mobile handler, desktop sidebar; both
/// mutate the map via `refreshWorktrees`) plus PR-poll deltas. Same
/// re-arming `withObservationTracking` + 80 ms trailing throttle as
/// ``SupermuxMobileProjectsObserver``.
@MainActor
final class SupermuxMobileWorktreesObserver {
    private let projectsModel: SupermuxProjectsModel
    private let pullRequestModel: SupermuxWorktreePullRequestModel
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private var lastSummaryHash: Int = 0
    /// The scheduled trailing pass; `nil` when idle. Its presence is the
    /// throttle: at most one emit-check per window.
    private var pendingPass: Task<Void, Never>?
    /// Throttle window, mirroring `MobileWorkspaceListObserver`.
    private let throttleMilliseconds: Int = 80

    /// Creates the observer and emits the initial snapshot unconditionally so
    /// freshly-paired clients see current state without waiting for a mutation.
    ///
    /// - Parameters:
    ///   - projectsModel: The app-wide projects model (worktree lists).
    ///   - pullRequestModel: The app-wide unopened-worktree PR model.
    ///   - emit: The event sink; defaults to `MobileHostService.emitEvent`.
    init(
        projectsModel: SupermuxProjectsModel,
        pullRequestModel: SupermuxWorktreePullRequestModel,
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        }
    ) {
        self.projectsModel = projectsModel
        self.pullRequestModel = pullRequestModel
        self.emit = emit
        emitIfNeededAndRearm(force: true)
    }

    deinit {
        pendingPass?.cancel()
    }

    /// Schedules the trailing emit pass unless one is already pending.
    private func modelDidChange() {
        guard pendingPass == nil else { return }
        pendingPass = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.throttleMilliseconds ?? 80) * 1_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingPass = nil
            self.emitIfNeededAndRearm(force: false)
        }
    }

    /// Reads the summary hash (re-arming observation atomically with the
    /// read), emits when it changed, and stores the new value.
    private func emitIfNeededAndRearm(force: Bool) {
        let hash = withObservationTracking {
            Self.summaryHash(
                worktreesByProjectId: projectsModel.worktreesByProjectId,
                pullRequestsByWorktreePath: pullRequestModel.pullRequestsByWorktreePath
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.modelDidChange()
            }
        }
        if !force, hash == lastSummaryHash {
            return
        }
        lastSummaryHash = hash
        emit(SupermuxMobileTopic.worktreesUpdated.rawValue, [:])
    }

    /// Stable hash of the iOS-facing projection: every project's worktree list
    /// plus the PR badge map the list payload folds in.
    private static func summaryHash(
        worktreesByProjectId: [UUID: [SupermuxProjectWorktree]],
        pullRequestsByWorktreePath: [String: SupermuxPullRequest]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(worktreesByProjectId)
        hasher.combine(pullRequestsByWorktreePath)
        return hasher.finalize()
    }
}

/// One-shot activation for the fork's mobile observers, called from the
/// `mobile-supermux-observers` fence where upstream constructs its own
/// `MobileWorkspaceListObserver` — so fork observers exist exactly when
/// upstream's mobile event plane is live.
@MainActor
enum SupermuxMobileHostGlue {
    private static var projectsObserver: SupermuxMobileProjectsObserver?
    private static var activityObserver: SupermuxMobileActivityObserver?
    private static var worktreesObserver: SupermuxMobileWorktreesObserver?

    /// Constructs the fork observers once; later calls are no-ops.
    static func activateIfNeeded() {
        guard projectsObserver == nil else { return }
        projectsObserver = SupermuxMobileProjectsObserver(model: SupermuxComposition.projectsModel)
        activityObserver = SupermuxMobileActivityObserver(
            projectsModel: SupermuxComposition.projectsModel,
            associations: SupermuxComposition.workspaceAssociations
        )
        worktreesObserver = SupermuxMobileWorktreesObserver(
            projectsModel: SupermuxComposition.projectsModel,
            pullRequestModel: SupermuxComposition.worktreePullRequestModel
        )
    }
}

import SwiftUI
import Foundation

/// The `.task(id:)` identity for the worktree PR probe: the task restarts
/// whenever the target set changed (expand/collapse, worktree created/deleted,
/// opened/closed) or the host's polling policy changed. A plain `Equatable`
/// value — not an interpolated string — so each render-pass comparison is a
/// field-wise equality with no per-pass formatting, and distinct target sets
/// can never collide.
struct SupermuxWorktreeProbeToken: Equatable {
    let policy: SupermuxPullRequestPollingPolicy
    /// Sorted by `(path, branch)` so an order-only change in the computed
    /// target list never restarts the probe.
    let targets: [SupermuxPullRequestTarget]
}

/// The unopened-worktree pull-request probe driven by
/// ``SupermuxProjectsSectionView``'s `.task(id:)`.
extension SupermuxProjectsSectionView {
    /// The unopened worktrees (under expanded projects) to probe for pull
    /// requests. Opened worktrees nest as workspace rows and reuse cmux's own
    /// probe, so they are excluded here. Empty while the host's PR polling
    /// settings disable probing, and while the whole section is collapsed
    /// (every row is hidden, so polling would only feed invisible badges).
    var worktreePullRequestTargets: [SupermuxPullRequestTarget] {
        guard pullRequestPolling.isEnabled, !model.isSectionCollapsed else { return [] }
        let openDirectories = SupermuxUnopenedWorktrees.openDirectories(openWorkspaces)
        var targets: [SupermuxPullRequestTarget] = []
        for project in model.projects where model.expandedProjectIds.contains(project.id) {
            for worktree in model.worktreesByProjectId[project.id] ?? [] {
                guard let branch = worktree.branch else { continue }
                if SupermuxUnopenedWorktrees.isOpen(worktree, openDirectories: openDirectories) { continue }
                targets.append(SupermuxPullRequestTarget(path: worktree.path, branch: branch))
            }
        }
        return targets
    }

    /// The probe task's restart identity — see ``SupermuxWorktreeProbeToken``.
    var worktreePullRequestProbeToken: SupermuxWorktreeProbeToken {
        SupermuxWorktreeProbeToken(
            policy: pullRequestPolling,
            targets: worktreePullRequestTargets.sorted {
                ($0.path, $0.branch) < ($1.path, $1.branch)
            }
        )
    }

    /// One `.task(id: worktreePullRequestProbeToken)` pass: resolves the
    /// current targets, then re-polls on the policy interval until the token
    /// changes and the task is replaced.
    func runWorktreePullRequestProbe() async {
        // Wire the deinit token to the model before the FIRST refresh ever
        // registers this client, so a whole-window close (no onDisappear; see
        // SupermuxPullRequestClientToken) can always deregister it. This is
        // the single entry point for every refresh from this section, making
        // the ordering guaranteed by construction; re-assignment on task
        // restarts is an idempotent weak-pointer store.
        pullRequestClientToken.model = pullRequestModel
        // Polling disabled by the host's settings: clear any badges and stop.
        guard pullRequestPolling.isEnabled else {
            await pullRequestModel.refresh(targets: [], allowCache: true, client: pullRequestClientToken.id)
            return
        }
        // Collapsed section: pause polling but keep the resolved badges for
        // instant redisplay — expanding changes the token, which restarts
        // this task with the real targets.
        guard !model.isSectionCollapsed else { return }
        let targets = worktreePullRequestTargets
        guard !targets.isEmpty else {
            await pullRequestModel.refresh(targets: [], allowCache: true, client: pullRequestClientToken.id)
            return
        }
        while !Task.isCancelled {
            // Cached results are allowed on every pass: the probe's repo-cache
            // freshness window (15s) only dedupes expand/collapse churn and
            // multi-window overlap — an empty cache still fetches, branches a
            // fresh entry doesn't cover get targeted lookups, and the poll
            // interval exceeds the window so periodic passes still fetch.
            await pullRequestModel.refresh(targets: targets, allowCache: true, client: pullRequestClientToken.id)
            try? await Task.sleep(for: pullRequestPolling.interval)
        }
    }

    /// This project's resolved unopened-worktree pull requests, keyed by worktree
    /// path — the immutable value snapshot handed to its row.
    func worktreePullRequests(for projectId: UUID) -> [String: SupermuxPullRequest] {
        let resolved = pullRequestModel.pullRequestsByWorktreePath
        guard !resolved.isEmpty, let worktrees = model.worktreesByProjectId[projectId] else { return [:] }
        var result: [String: SupermuxPullRequest] = [:]
        for worktree in worktrees where resolved[worktree.path] != nil {
            result[worktree.path] = resolved[worktree.path]
        }
        return result
    }
}

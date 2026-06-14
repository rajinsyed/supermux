import Foundation
public import Observation
import CmuxGit

/// Owns pull-request badges for **unopened** worktrees in the Projects sidebar.
///
/// Opened worktrees nest as live workspace rows whose PR comes straight from
/// cmux's own probe (carried on ``SupermuxOpenWorkspace/pullRequest``); this
/// model fills the gap for worktrees that exist on disk but have no open
/// workspace, so their disclosure rows show the same badge. It drives
/// ``SupermuxPullRequestProbe`` (cmux's `CmuxGit` pipeline) and owns the repo
/// cache between passes.
///
/// As a `@MainActor @Observable` it is observed by the *section* view, which
/// reads ``pullRequestsByWorktreePath`` and passes per-worktree values down to
/// rows — rows never hold this model, preserving the sidebar snapshot boundary.
@MainActor
@Observable
public final class SupermuxWorktreePullRequestModel {
    /// The resolved pull request per worktree path; paths absent from the map
    /// have no badge.
    public private(set) var pullRequestsByWorktreePath: [String: SupermuxPullRequest] = [:]

    @ObservationIgnored private let probe: SupermuxPullRequestProbe
    /// Caller-owned repo cache reused across refreshes (the probe's 15s
    /// freshness window keeps worktrees that share a repo from re-fetching).
    @ObservationIgnored private var repoCache: [String: WorkspacePullRequestRepoCacheEntry] = [:]

    /// Creates the model.
    /// - Parameter probe: PR probe; defaults to the production one.
    public init(probe: SupermuxPullRequestProbe = SupermuxPullRequestProbe()) {
        self.probe = probe
    }

    /// Refreshes badges for the given worktrees and prunes paths no longer tracked.
    ///
    /// Resolved targets set or update their badge; absent targets (no PR, a
    /// default branch, or no GitHub remote) clear theirs; transient failures keep
    /// the existing badge. ``pullRequestsByWorktreePath`` is only reassigned when
    /// the map actually changes, so a steady-state poll never rebuilds rows.
    /// - Parameters:
    ///   - targets: The unopened worktrees to resolve (path + branch).
    ///   - allowCache: Whether the probe may serve fresh cache entries.
    public func refresh(targets: [SupermuxPullRequestTarget], allowCache: Bool) async {
        guard !targets.isEmpty else {
            if !pullRequestsByWorktreePath.isEmpty {
                pullRequestsByWorktreePath = [:]
            }
            return
        }

        let outcome = await probe.resolve(targets: targets, cache: repoCache, allowCache: allowCache)
        repoCache = outcome.updatedCache

        let updated = Self.applying(
            outcome.resolutions,
            to: pullRequestsByWorktreePath,
            trackedPaths: Set(targets.map(\.path))
        )
        // Only publish when the map actually changed, so a steady-state poll
        // never rebuilds rows (snapshot-boundary CPU rule).
        if updated != pullRequestsByWorktreePath {
            pullRequestsByWorktreePath = updated
        }
    }

    /// Applies probe resolutions onto the current badge map and prunes paths no
    /// longer tracked: resolved targets set/update their badge, absent targets
    /// clear theirs, transient failures keep the existing one.
    ///
    /// Pure and `nonisolated` so the merge/prune logic is unit-testable without
    /// the network probe.
    /// - Parameters:
    ///   - resolutions: Per-path probe outcomes.
    ///   - existing: The current badge map.
    ///   - trackedPaths: Paths still being tracked; others are pruned.
    nonisolated static func applying(
        _ resolutions: [SupermuxPullRequestProbe.PathResolution],
        to existing: [String: SupermuxPullRequest],
        trackedPaths: Set<String>
    ) -> [String: SupermuxPullRequest] {
        var updated = existing
        for entry in resolutions {
            switch entry.resolution {
            case .pullRequest(let pullRequest):
                updated[entry.path] = pullRequest
            case .absent:
                updated[entry.path] = nil
            case .keepExisting:
                break
            }
        }
        return updated.filter { trackedPaths.contains($0.key) }
    }
}

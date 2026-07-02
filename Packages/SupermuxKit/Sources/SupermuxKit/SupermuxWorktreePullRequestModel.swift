public import Foundation
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
///
/// The model may be shared across windows (one poll pass and one repo cache
/// serving every sidebar): each window's section refreshes with its own
/// `client` id, and badges are pruned to the **union** of all clients' tracked
/// paths so one window's pass never deletes another window's badges. Callers
/// that keep a private instance can omit the client id.
@MainActor
@Observable
public final class SupermuxWorktreePullRequestModel {
    /// Consecutive transient-failure passes after which a kept badge is marked
    /// stale (rendered dimmed), mirroring cmux's own stale-PR threshold.
    nonisolated static let staleFailureThreshold = 3

    /// How long an unrefreshed repo-cache entry survives. Passes only merge
    /// entries in (per-slug, freshest wins), so without an age cutoff every
    /// slug ever browsed would live until relaunch.
    nonisolated static let repoCacheEvictionAge: TimeInterval = 3600

    /// The resolved pull request per worktree path; paths absent from the map
    /// have no badge.
    public private(set) var pullRequestsByWorktreePath: [String: SupermuxPullRequest] = [:]

    @ObservationIgnored private let probe: any SupermuxPullRequestResolving
    /// Caller-owned repo cache reused across refreshes (the probe's 15s
    /// freshness window keeps worktrees that share a repo from re-fetching).
    @ObservationIgnored private var repoCache: [String: WorkspacePullRequestRepoCacheEntry] = [:]
    /// Tracked worktree paths per client (one client per window's section).
    /// Badges are pruned to the union of these sets.
    @ObservationIgnored private var trackedPathsByClient: [UUID: Set<String>] = [:]
    /// Consecutive transient-failure count per path, for stale escalation.
    @ObservationIgnored private var failureCounts: [String: Int] = [:]
    /// Token identifying each client's newest
    /// ``refresh(targets:allowCache:client:)``. A pass that suspended in the
    /// probe drops its result when the SAME client started a newer pass
    /// meanwhile (its view task was replaced or its targets cleared), so a
    /// stale pass can't clobber fresh state. Tokens are drawn from the single
    /// monotonic ``nextGeneration`` counter — never restarted per client — so
    /// a client removed by ``endTracking(client:)`` and later re-registered
    /// under the same id can never mint a token equal to a stale
    /// pre-`endTracking` pass's token. The comparison map stays per-client on
    /// purpose: with the model shared app-wide, different windows' passes
    /// routinely overlap and carry disjoint target sets — a global comparison
    /// would throw one window's resolutions away whenever another window's
    /// pass started, starving its badges every poll round.
    @ObservationIgnored private var refreshGenerationByClient: [UUID: Int] = [:]
    /// Source of every refresh generation token (see
    /// ``refreshGenerationByClient``).
    @ObservationIgnored private var nextGeneration = 0
    /// Client id used for refreshes that don't pass one (unshared instances).
    private static let soleClient = UUID()

    /// Creates the model.
    /// - Parameter probe: PR resolver; defaults to the production probe.
    public init(probe: any SupermuxPullRequestResolving = SupermuxPullRequestProbe()) {
        self.probe = probe
    }

    /// Refreshes badges for the given worktrees and prunes paths no longer
    /// tracked by any client.
    ///
    /// Resolved targets set or update their badge; absent targets (no PR, a
    /// default branch, or no GitHub remote) clear theirs; transient failures keep
    /// the existing badge, marking it stale after
    /// ``staleFailureThreshold`` consecutive failures.
    /// ``pullRequestsByWorktreePath`` is only reassigned when the map actually
    /// changes, so a steady-state poll never rebuilds rows.
    /// - Parameters:
    ///   - targets: The unopened worktrees to resolve (path + branch). Empty
    ///     stops tracking for this client and prunes its exclusive badges.
    ///   - allowCache: Whether the probe may serve fresh cache entries.
    ///   - client: Identifies the calling window's section when the model is
    ///     shared; omit for a private, single-window instance.
    public func refresh(
        targets: [SupermuxPullRequestTarget],
        allowCache: Bool,
        client: UUID? = nil
    ) async {
        // Bump before any early return so this client's in-flight older pass
        // is always invalidated, including by a clearing pass.
        let clientId = client ?? Self.soleClient
        nextGeneration &+= 1
        let generation = nextGeneration
        refreshGenerationByClient[clientId] = generation
        trackedPathsByClient[clientId] = targets.isEmpty ? nil : Set(targets.map(\.path))

        guard !targets.isEmpty else {
            pruneToTrackedPaths()
            return
        }

        let outcome = await probe.resolve(
            targets: targets,
            cache: repoCache,
            allowCache: allowCache,
            now: Date()
        )
        // A newer pass from the SAME client superseded this one while it was
        // suspended in the probe (its view task was replaced, or its targets
        // cleared / tracking ended): drop the result before touching the cache
        // or the badge map so the stale pass can't clobber the replacement's
        // fresh state. Other clients' passes carry disjoint targets and merge
        // safely, so they never invalidate this one.
        guard generation == refreshGenerationByClient[clientId], !Task.isCancelled else { return }
        // Merge per-slug keeping the freshest entry: with concurrent passes
        // from different windows, whole-map assignment would let the pass that
        // *finishes* last regress another client's newer cache entries. Then
        // evict entries no pass has refreshed within the age cutoff so the
        // merge-only accumulation stays bounded across long app sessions.
        repoCache.merge(outcome.updatedCache) { current, incoming in
            incoming.fetchedAt >= current.fetchedAt ? incoming : current
        }
        let cutoff = Date().addingTimeInterval(-Self.repoCacheEvictionAge)
        repoCache = repoCache.filter { $0.value.fetchedAt >= cutoff }

        let applied = Self.applying(
            outcome.resolutions,
            to: pullRequestsByWorktreePath,
            trackedPaths: trackedPaths,
            failureCounts: failureCounts
        )
        failureCounts = applied.failureCounts
        publishIfChanged(applied.badges)
    }

    /// Stops tracking a client's targets (e.g. its window closed) and prunes
    /// badges no other client still tracks. No-op for unknown clients.
    /// - Parameter client: The client id previously passed to `refresh`.
    public func endTracking(client: UUID) {
        // Dropping the generation entry both invalidates the client's
        // in-flight pass (its guard sees nil) and keeps the map from growing
        // across window open/close cycles.
        refreshGenerationByClient.removeValue(forKey: client)
        guard trackedPathsByClient.removeValue(forKey: client) != nil else { return }
        pruneToTrackedPaths()
    }

    // MARK: - Internals

    /// The union of every client's tracked paths.
    private var trackedPaths: Set<String> {
        trackedPathsByClient.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    private func pruneToTrackedPaths() {
        let tracked = trackedPaths
        failureCounts = failureCounts.filter { tracked.contains($0.key) }
        publishIfChanged(pullRequestsByWorktreePath.filter { tracked.contains($0.key) })
    }

    /// Only publish when the map actually changed, so a steady-state poll
    /// never rebuilds rows (snapshot-boundary CPU rule).
    private func publishIfChanged(_ updated: [String: SupermuxPullRequest]) {
        if updated != pullRequestsByWorktreePath {
            pullRequestsByWorktreePath = updated
        }
    }

    /// Applies probe resolutions onto the current badge map and prunes paths no
    /// longer tracked: resolved targets set/update their badge, absent targets
    /// clear theirs, transient failures keep the existing one — marked stale
    /// (rendered dimmed) once ``staleFailureThreshold`` consecutive failures
    /// accumulate for a path. Success or absence resets the path's count.
    ///
    /// Pure and `nonisolated` so the merge/prune/staleness logic is
    /// unit-testable without the network probe.
    /// - Parameters:
    ///   - resolutions: Per-path probe outcomes.
    ///   - existing: The current badge map.
    ///   - trackedPaths: Paths still being tracked; others are pruned.
    ///   - failureCounts: Consecutive transient-failure counts entering this pass.
    /// - Returns: The updated badge map and failure counts (both pruned).
    nonisolated static func applying(
        _ resolutions: [SupermuxPullRequestProbe.PathResolution],
        to existing: [String: SupermuxPullRequest],
        trackedPaths: Set<String>,
        failureCounts: [String: Int] = [:]
    ) -> (badges: [String: SupermuxPullRequest], failureCounts: [String: Int]) {
        var updated = existing
        var counts = failureCounts
        for entry in resolutions {
            switch entry.resolution {
            case .pullRequest(let pullRequest):
                updated[entry.path] = pullRequest
                counts[entry.path] = nil
            case .absent:
                updated[entry.path] = nil
                counts[entry.path] = nil
            case .keepExisting:
                let count = (counts[entry.path] ?? 0) + 1
                counts[entry.path] = count
                if count >= staleFailureThreshold,
                   let kept = updated[entry.path], !kept.isStale {
                    updated[entry.path] = SupermuxPullRequest(
                        number: kept.number,
                        status: kept.status,
                        url: kept.url,
                        isStale: true
                    )
                }
            }
        }
        return (
            badges: updated.filter { trackedPaths.contains($0.key) },
            failureCounts: counts.filter { trackedPaths.contains($0.key) }
        )
    }
}

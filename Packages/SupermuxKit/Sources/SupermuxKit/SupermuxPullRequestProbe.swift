public import Foundation
public import CmuxGit

/// One worktree to look up a pull request for: its checkout path (which keys the
/// result) and the branch checked out there.
public struct SupermuxPullRequestTarget: Hashable, Sendable {
    /// Absolute worktree path; also the key the resolved PR is stored under.
    public let path: String
    /// The branch checked out in the worktree.
    public let branch: String

    /// Creates a probe target.
    /// - Parameters:
    ///   - path: Absolute worktree path.
    ///   - branch: The checked-out branch to look up.
    public init(path: String, branch: String) {
        self.path = path
        self.branch = branch
    }
}

/// Abstraction over ``SupermuxPullRequestProbe`` so
/// ``SupermuxWorktreePullRequestModel`` can be unit-tested with a scripted
/// resolver instead of the network pipeline.
public protocol SupermuxPullRequestResolving: Sendable {
    /// Looks up the pull request for each target, reusing/refreshing the cache.
    /// See ``SupermuxPullRequestProbe/resolve(targets:cache:allowCache:now:)``.
    func resolve(
        targets: [SupermuxPullRequestTarget],
        cache: [String: WorkspacePullRequestRepoCacheEntry],
        allowCache: Bool,
        now: Date
    ) async -> SupermuxPullRequestProbe.Outcome
}

/// Resolves pull requests for unopened worktrees by reusing cmux's
/// ``CmuxGit/PullRequestProbeService`` pipeline.
///
/// cmux already probes PRs for *opened* workspace panels, and supermux reuses
/// that state directly for nested workspace rows. This probe covers the gap:
/// worktrees that exist on disk but have no open workspace, so the disclosure
/// rows can show the same badge. It is a thin, stateless wrapper — the caller
/// (``SupermuxWorktreePullRequestModel``) owns the repo cache and passes it back
/// on each call.
public struct SupermuxPullRequestProbe: Sendable {
    /// How one target resolved, for the owning model to apply.
    public enum Resolution: Sendable {
        /// A pull request was found for the branch.
        case pullRequest(SupermuxPullRequest)
        /// No pull request applies (none found, a default branch, or the
        /// directory has no GitHub remote).
        case absent
        /// The lookup failed transiently (network/auth); keep any existing badge.
        case keepExisting
    }

    /// One target's path paired with how it resolved.
    public struct PathResolution: Sendable {
        /// The worktree path the resolution applies to.
        public let path: String
        /// How the lookup resolved.
        public let resolution: Resolution

        /// Creates a per-path resolution.
        public init(path: String, resolution: Resolution) {
            self.path = path
            self.resolution = resolution
        }
    }

    /// The result of a probe pass: a per-path resolution plus the refreshed cache.
    public struct Outcome: Sendable {
        /// Resolution per target, in input order.
        public let resolutions: [PathResolution]
        /// The repo cache to hand back on the next pass.
        public let updatedCache: [String: WorkspacePullRequestRepoCacheEntry]

        /// Creates a probe outcome.
        public init(resolutions: [PathResolution], updatedCache: [String: WorkspacePullRequestRepoCacheEntry]) {
            self.resolutions = resolutions
            self.updatedCache = updatedCache
        }
    }

    private let service: PullRequestProbeService
    private let gitMetadata: GitMetadataService

    /// Creates a probe.
    /// - Parameters:
    ///   - service: cmux's PR probe pipeline; defaults to the production one.
    ///   - gitMetadata: Reader used to resolve each directory's GitHub remotes.
    public init(
        service: PullRequestProbeService = PullRequestProbeService(),
        gitMetadata: GitMetadataService = GitMetadataService()
    ) {
        self.service = service
        self.gitMetadata = gitMetadata
    }

    /// Looks up the pull request for each target, reusing/refreshing the cache.
    /// - Parameters:
    ///   - targets: Worktrees to resolve (path + branch).
    ///   - cache: The caller-owned repo cache from the previous pass.
    ///   - allowCache: Whether fresh cache entries may satisfy the fetch
    ///     (periodic polls pass `true`; the first/forced pass passes `false`).
    ///   - now: Timestamp for cache-freshness checks; defaults to the current time.
    /// - Returns: A per-path resolution plus the refreshed cache.
    public func resolve(
        targets: [SupermuxPullRequestTarget],
        cache: [String: WorkspacePullRequestRepoCacheEntry],
        allowCache: Bool,
        now: Date = Date()
    ) async -> Outcome {
        // Default branches never earn a badge; resolve them as absent without a
        // network call, matching cmux's own skip rule.
        let probeTargets = targets.filter { !PullRequestProbeService.shouldSkipLookup(branch: $0.branch) }
        guard !probeTargets.isEmpty else {
            return Outcome(
                resolutions: targets.map { PathResolution(path: $0.path, resolution: .absent) },
                updatedCache: cache
            )
        }

        // One seed per target; `resolveCandidateSeeds` emits candidates in seed
        // order and `resolveRefreshResults` preserves it, so results correlate to
        // targets by index.
        let seeds = probeTargets.map { target in
            WorkspacePullRequestCandidateSeed(
                workspaceId: UUID(),
                panelId: UUID(),
                branch: target.branch,
                directory: target.path
            )
        }
        let resolution = await service.resolveCandidateSeeds(seeds, gitMetadata: gitMetadata)
        // fetchRepoResults returns (repoResults, rateLimitRetryDate) since cmux
        // 0.65; the coordinator inside CmuxGit already enforces the retry
        // deadline for subsequent fetches, so the probe only consumes the
        // per-repo results.
        let (repoResults, _) = await service.fetchRepoResults(
            repoDirectoriesBySlug: resolution.repoDirectoriesBySlug,
            candidateBranchesByRepo: resolution.candidateBranchesByRepo,
            cacheBySlug: cache,
            now: now,
            allowCachedResults: allowCache
        )
        let refreshResults = PullRequestProbeService.resolveRefreshResults(
            candidates: resolution.candidates,
            repoResults: repoResults
        )

        var resolutions: [PathResolution] = []
        resolutions.reserveCapacity(targets.count)
        for (target, result) in zip(probeTargets, refreshResults) {
            switch result.resolution {
            case .resolved(let item):
                if let pullRequest = SupermuxPullRequest(resolvedItem: item) {
                    resolutions.append(PathResolution(path: target.path, resolution: .pullRequest(pullRequest)))
                } else {
                    resolutions.append(PathResolution(path: target.path, resolution: .absent))
                }
            case .notFound, .unsupportedRepository:
                resolutions.append(PathResolution(path: target.path, resolution: .absent))
            case .transientFailure:
                resolutions.append(PathResolution(path: target.path, resolution: .keepExisting))
            }
        }
        // Skipped (default-branch) targets resolve as absent so the model clears
        // any leftover badge for them.
        let probedPaths = Set(probeTargets.map(\.path))
        for target in targets where !probedPaths.contains(target.path) {
            resolutions.append(PathResolution(path: target.path, resolution: .absent))
        }

        // Fold successful repo fetches back into the cache; leave failed slugs on
        // their previous entry so a transient failure doesn't evict good data.
        var updatedCache = cache
        for (slug, result) in repoResults {
            if case .success(let entry, _, _) = result {
                updatedCache[slug] = entry
            }
        }
        return Outcome(resolutions: resolutions, updatedCache: updatedCache)
    }
}

extension SupermuxPullRequestProbe: SupermuxPullRequestResolving {}

extension SupermuxPullRequest {
    /// Bridges a `CmuxGit` probe result into a badge value, or `nil` when the URL
    /// or status string can't be parsed.
    init?(resolvedItem item: WorkspacePullRequestResolvedItem) {
        guard let url = URL(string: item.urlString),
              let status = Status(rawValue: item.statusRawValue) else {
            return nil
        }
        self.init(number: item.number, status: status, url: url, isStale: false)
    }
}

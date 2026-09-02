public import Foundation
public import Observation
import CmuxGit

/// State for the Changes panel's pull-request viewer.
///
/// **Nothing loads until the user asks.** The model holds no timer and no
/// watcher: ``open(_:)`` (a click on a header PR button) and
/// ``refresh()`` (the viewer's refresh button) are the only entry points that
/// touch the network, so the panel costs nothing while it sits idle. Loaded
/// details are cached per PR number for the current directory, so re-opening
/// a PR is instant and only an explicit refresh re-fetches.
///
/// The header's PR buttons come from two free sources merged by
/// ``visibleButtons(known:)``: the PR cmux already tracks for the workspace
/// (its own sidebar probe, no new background work) and the branch's PR list
/// from the last on-demand load.
@MainActor
@Observable
public final class SupermuxPullRequestViewerModel {
    /// The working directory the viewer is showing PRs for.
    public private(set) var directory: String?
    /// The branch the viewer lists PRs for.
    public private(set) var branch: String?
    /// The PRs (open, merged or closed, newest first) for ``branch`` from the
    /// last on-demand load.
    public private(set) var pullRequests: [SupermuxPullRequestSummary] = []
    /// Whether ``pullRequests`` reflects a completed load for this context.
    public private(set) var hasLoadedList = false
    /// The PR the viewer is showing; `nil` shows the regular changes list.
    public private(set) var selected: SupermuxPullRequestSummary?
    /// Loaded details keyed by ``SupermuxPullRequestSummary/id`` (`owner/repo#N`).
    public private(set) var details: [String: SupermuxPullRequestDetail] = [:]
    /// Whether a load is in flight.
    public private(set) var isLoading = false
    /// The last load's error, cleared by the next successful load.
    public private(set) var errorMessage: String?
    /// When the last successful load finished.
    public private(set) var lastLoadedAt: Date?

    @ObservationIgnored private let provider: any SupermuxPullRequestDetailProviding
    @ObservationIgnored private let slugResolver: @Sendable (String) async -> [String]
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Bumped on every context change so a load for a previous directory
    /// discards its result instead of overwriting the new one.
    @ObservationIgnored private var generation = 0
    /// In-flight loads for the current context; ``isLoading`` is derived from
    /// it so two quick clicks (PR A, then PR B) both complete and the spinner
    /// stays until the last one lands.
    @ObservationIgnored private var inflightLoads = 0
    /// Sequence number of the most recently started load. Only that load may
    /// write ``errorMessage`` and ``lastLoadedAt``: a slower, older load that
    /// lands afterwards still contributes its cached details but must not
    /// attach its error to (or wipe a real error from) the PR now shown.
    @ObservationIgnored private var latestLoadID = 0

    /// Creates the model.
    /// - Parameters:
    ///   - provider: PR lookups; defaults to the GitHub REST service.
    ///   - slugResolver: Maps a directory to its GitHub `owner/repo` slugs;
    ///     defaults to cmux's git-metadata reader.
    ///   - now: Clock, injectable for tests.
    public init(
        provider: any SupermuxPullRequestDetailProviding = SupermuxPullRequestDetailService(),
        slugResolver: (@Sendable (String) async -> [String])? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.slugResolver = slugResolver ?? { directory in
            await GitMetadataService().repositorySlugs(forDirectory: directory)
        }
        self.now = now
    }

    /// The detail for ``selected``, once loaded.
    public var selectedDetail: SupermuxPullRequestDetail? {
        selected.flatMap { details[$0.id] }
    }

    /// Points the viewer at a workspace. A change of directory or branch
    /// drops every cached PR, closes the viewer and discards in-flight loads;
    /// an unchanged context is a no-op so re-renders never reset state.
    public func setContext(directory: String?, branch: String?) {
        guard directory != self.directory || branch != self.branch else { return }
        self.directory = directory
        self.branch = branch
        generation += 1
        inflightLoads = 0
        latestLoadID = 0
        pullRequests = []
        hasLoadedList = false
        selected = nil
        details = [:]
        isLoading = false
        errorMessage = nil
        lastLoadedAt = nil
    }

    /// The header buttons: the PR cmux already knows for the workspace plus
    /// the PRs from the last on-demand load, de-duplicated by repo + number.
    /// - Parameter known: The workspace's PR from cmux's own sidebar probe.
    public func visibleButtons(known: SupermuxPullRequest?) -> [SupermuxPullRequestSummary] {
        Self.visibleButtons(known: known, fetched: pullRequests)
    }

    /// Pure merge behind ``visibleButtons(known:)``: open, merged and closed
    /// PRs all earn a chip (colored by state, like the sidebar badge); a
    /// fetched entry wins over the bare known badge for the same repo +
    /// number (it carries the title); a known PR the fetch did not see stays
    /// (cmux's probe may be fresher than the last on-demand load). The known
    /// badge's repository comes from its URL, so a fork's `#49` is never
    /// confused with upstream's `#49`.
    nonisolated static func visibleButtons(
        known: SupermuxPullRequest?,
        fetched: [SupermuxPullRequestSummary]
    ) -> [SupermuxPullRequestSummary] {
        var buttons = fetched
        if let known,
           let summary = SupermuxPullRequestSummary(known: known),
           !fetched.contains(where: { $0.id == summary.id }) {
            buttons.insert(summary, at: 0)
        }
        return buttons
    }

    /// Shows a PR in the viewer, loading it (and the branch's PR list, the
    /// first time) unless it is already cached. Clicking the selected PR's button
    /// again closes the viewer.
    public func open(_ pullRequest: SupermuxPullRequestSummary) {
        if selected?.id == pullRequest.id {
            close()
            return
        }
        selected = pullRequest
        errorMessage = nil
        if details[pullRequest.id] == nil || !hasLoadedList {
            startLoad(targets: [pullRequest], reloadList: !hasLoadedList)
        }
    }

    /// Returns to the regular changes list. Cached details are kept.
    public func close() {
        selected = nil
    }

    /// Re-fetches the branch's PR list and the selected PR's detail.
    public func refresh() {
        startLoad(targets: selected.map { [$0] } ?? [], reloadList: true)
    }

    // MARK: - Loading

    private func startLoad(targets: [SupermuxPullRequestSummary], reloadList: Bool) {
        guard let directory else { return }
        let generation = generation
        let branch = branch
        latestLoadID += 1
        let loadID = latestLoadID
        inflightLoads += 1
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.load(directory: directory, branch: branch, targets: targets, reloadList: reloadList)
            // A context change while suspended reset the counter and dropped
            // this pass's cache; its result is for a directory no longer shown.
            guard generation == self.generation else { return }
            self.inflightLoads -= 1
            self.apply(outcome, isLatest: loadID == self.latestLoadID)
        }
    }

    private struct LoadOutcome {
        /// The merged PR list, when one was requested.
        var list: [SupermuxPullRequestSummary]?
        /// Whether every remote's list query succeeded. A partial list is
        /// still shown but not marked loaded, so the next click retries it.
        var listIsComplete = false
        var details: [String: SupermuxPullRequestDetail] = [:]
        /// The error worth showing: a failed target detail, or a list load
        /// that produced nothing at all. One remote failing while another
        /// answered is not an error the user can act on.
        var error: (any Error)?
    }

    /// Lists the branch's PRs across every GitHub remote of the checkout and
    /// loads each target from the repository its summary names.
    ///
    /// The list queries each remote's repository for heads pushed by each
    /// remote's owner: a fork checkout (`origin` = `me/repo`, `upstream` =
    /// `org/repo`) then finds both a same-repo PR and a fork-to-upstream PR
    /// (`org/repo` with head `me:branch`). Results are de-duplicated by URL.
    private func load(
        directory: String, branch: String?, targets: [SupermuxPullRequestSummary], reloadList: Bool
    ) async -> LoadOutcome {
        var outcome = LoadOutcome()
        let slugs = await slugResolver(directory)
        guard !slugs.isEmpty else {
            outcome.error = SupermuxGitHubError.notAGitHubRepository
            return outcome
        }
        if reloadList, let branch {
            var list: [SupermuxPullRequestSummary] = []
            var seen: Set<URL> = []
            var listError: (any Error)?
            var succeededQueries = 0
            for (slug, owner) in Self.listQueries(slugs: slugs) {
                do {
                    for summary in try await provider.pullRequests(repositorySlug: slug, headOwner: owner, branch: branch)
                    where seen.insert(summary.url).inserted {
                        list.append(summary)
                    }
                    succeededQueries += 1
                } catch {
                    listError = error
                }
            }
            outcome.list = list
            outcome.listIsComplete = listError == nil
            if succeededQueries == 0 {
                outcome.error = listError
            }
        }
        for target in targets {
            do {
                outcome.details[target.id] = try await provider.detail(
                    repositorySlug: target.repositorySlug, number: target.number
                )
            } catch {
                // What the user clicked on could not load; that always shows.
                outcome.error = error
            }
        }
        return outcome
    }

    /// Every (repository, head owner) pair to list: each slug crossed with
    /// each distinct owner among the slugs, the slug's own owner first.
    nonisolated static func listQueries(slugs: [String]) -> [(slug: String, owner: String)] {
        let owners = slugs.compactMap { $0.split(separator: "/").first.map(String.init) }
        var seenOwners: Set<String> = []
        let distinctOwners = owners.filter { seenOwners.insert($0).inserted }
        var queries: [(slug: String, owner: String)] = []
        for (slug, own) in zip(slugs, owners) {
            queries.append((slug, own))
            for other in distinctOwners where other != own {
                queries.append((slug, other))
            }
        }
        return queries
    }

    /// Folds a finished load into the model. Details and the list are always
    /// kept (they are cached data, useful whichever load fetched them); the
    /// error banner and timestamp belong to the latest load only.
    private func apply(_ outcome: LoadOutcome, isLatest: Bool) {
        isLoading = inflightLoads > 0
        if let list = outcome.list {
            pullRequests = list
            hasLoadedList = outcome.listIsComplete
        }
        details.merge(outcome.details) { _, new in new }
        guard isLatest else { return }
        if let error = outcome.error {
            errorMessage = error.localizedDescription
        } else {
            errorMessage = nil
            lastLoadedAt = now()
        }
    }
}

public import Foundation
public import Observation
import CmuxGit

/// State for the Changes panel's pull-request viewer.
///
/// **Nothing loads until the user asks.** The model holds no timer and no
/// watcher: ``open(number:)`` (a click on a header PR button) and
/// ``refresh()`` (the viewer's refresh button) are the only entry points that
/// touch the network, so the panel costs nothing while it sits idle. Loaded
/// details are cached per PR number for the current directory, so re-opening
/// a PR is instant and only an explicit refresh re-fetches.
///
/// The header's PR buttons come from two free sources merged by
/// ``visibleButtons(known:)``: the PR cmux already tracks for the workspace
/// (its own sidebar probe, no new background work) and the open-PR list from
/// the last on-demand load.
@MainActor
@Observable
public final class SupermuxPullRequestViewerModel {
    /// The working directory the viewer is showing PRs for.
    public private(set) var directory: String?
    /// The branch the viewer lists PRs for.
    public private(set) var branch: String?
    /// The open PRs for ``branch`` from the last on-demand load.
    public private(set) var openPullRequests: [SupermuxPullRequestSummary] = []
    /// Whether ``openPullRequests`` reflects a completed load for this context.
    public private(set) var hasLoadedList = false
    /// The PR the viewer is showing; `nil` shows the regular changes list.
    public private(set) var selectedNumber: Int?
    /// Loaded details keyed by PR number.
    public private(set) var details: [Int: SupermuxPullRequestDetail] = [:]
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

    /// The detail for ``selectedNumber``, once loaded.
    public var selectedDetail: SupermuxPullRequestDetail? {
        selectedNumber.flatMap { details[$0] }
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
        openPullRequests = []
        hasLoadedList = false
        selectedNumber = nil
        details = [:]
        isLoading = false
        errorMessage = nil
        lastLoadedAt = nil
    }

    /// The header buttons: the open PR cmux already knows for the workspace
    /// plus the open PRs from the last on-demand load, de-duplicated by number.
    /// - Parameter known: The workspace's PR from cmux's own sidebar probe.
    public func visibleButtons(known: SupermuxPullRequest?) -> [SupermuxPullRequestSummary] {
        Self.visibleButtons(known: known, fetched: openPullRequests)
    }

    /// Pure merge behind ``visibleButtons(known:)``: only open PRs earn a
    /// button; a fetched entry wins over the bare known badge for the same
    /// number (it carries the title); a known PR the fetch did not see stays
    /// (cmux's probe may be fresher than the last on-demand load).
    nonisolated static func visibleButtons(
        known: SupermuxPullRequest?,
        fetched: [SupermuxPullRequestSummary]
    ) -> [SupermuxPullRequestSummary] {
        var buttons = fetched
        if let known, known.status == .open, !fetched.contains(where: { $0.number == known.number }) {
            buttons.insert(
                SupermuxPullRequestSummary(
                    number: known.number, title: known.title ?? "", url: known.url, isDraft: false
                ),
                at: 0
            )
        }
        return buttons
    }

    /// Shows `number` in the viewer, loading it (and the open-PR list, the
    /// first time) unless it is already cached. Clicking the selected PR's
    /// button again closes the viewer.
    public func open(number: Int) {
        if selectedNumber == number {
            close()
            return
        }
        selectedNumber = number
        errorMessage = nil
        if details[number] == nil || !hasLoadedList {
            startLoad(numbers: [number], reloadList: !hasLoadedList)
        }
    }

    /// Returns to the regular changes list. Cached details are kept.
    public func close() {
        selectedNumber = nil
    }

    /// Re-fetches the open-PR list and the selected PR's detail.
    public func refresh() {
        startLoad(numbers: selectedNumber.map { [$0] } ?? [], reloadList: true)
    }

    // MARK: - Loading

    private func startLoad(numbers: [Int], reloadList: Bool) {
        guard let directory else { return }
        let generation = generation
        let branch = branch
        inflightLoads += 1
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.load(directory: directory, branch: branch, numbers: numbers, reloadList: reloadList)
            // A context change while suspended reset the counter and dropped
            // this pass's cache; its result is for a directory no longer shown.
            guard generation == self.generation else { return }
            self.inflightLoads -= 1
            self.apply(outcome)
        }
    }

    private struct LoadOutcome {
        var list: [SupermuxPullRequestSummary]?
        var details: [Int: SupermuxPullRequestDetail] = [:]
        var error: (any Error)?
    }

    private func load(directory: String, branch: String?, numbers: [Int], reloadList: Bool) async -> LoadOutcome {
        var outcome = LoadOutcome()
        let slugs = await slugResolver(directory)
        guard let slug = slugs.first else {
            outcome.error = SupermuxGitHubError.notAGitHubRepository
            return outcome
        }
        if reloadList, let branch {
            do {
                outcome.list = try await provider.openPullRequests(repositorySlug: slug, branch: branch)
            } catch {
                outcome.error = error
            }
        }
        for number in numbers {
            do {
                outcome.details[number] = try await provider.detail(repositorySlug: slug, number: number)
            } catch {
                outcome.error = error
            }
        }
        return outcome
    }

    private func apply(_ outcome: LoadOutcome) {
        isLoading = inflightLoads > 0
        if let list = outcome.list {
            openPullRequests = list
            hasLoadedList = true
        }
        details.merge(outcome.details) { _, new in new }
        if let error = outcome.error {
            errorMessage = error.localizedDescription
        } else {
            errorMessage = nil
            lastLoadedAt = now()
        }
    }
}

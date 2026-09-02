import CmuxFoundation
import Foundation
import Testing
@testable import SupermuxKit

/// Tests the Changes panel's on-demand PR viewer: the pure decision rules on
/// ``SupermuxPullRequestDetail``, the REST mapping in
/// ``SupermuxPullRequestDetailService``, the GitHub client's token/header
/// contract, and ``SupermuxPullRequestViewerModel``'s load-on-click behavior.
struct SupermuxPullRequestViewerTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    private func detail(
        number: Int = 7,
        state: SupermuxPullRequestDetail.State = .open,
        mergeable: Bool? = true,
        mergeableState: String? = "clean",
        reviews: [SupermuxPullRequestReview] = [],
        checks: [SupermuxPullRequestCheck] = []
    ) -> SupermuxPullRequestDetail {
        SupermuxPullRequestDetail(
            number: number, title: "T", body: "", url: url("https://github.com/o/r/pull/\(number)"),
            state: state, author: "me", baseRef: "main", headRef: "feature", headSHA: "abc",
            createdAt: nil, updatedAt: nil, additions: 1, deletions: 2, changedFileCount: 1,
            commitCount: 1, commentCount: 0, mergeable: mergeable, mergeableState: mergeableState,
            labels: [], requestedReviewers: [], reviews: reviews, checks: checks, files: []
        )
    }

    // MARK: - Pure rules

    @Test func reviewDecisionPrefersChangeRequestsOverApprovals() {
        let approved = SupermuxPullRequestReview(reviewer: "a", state: .approved)
        let changes = SupermuxPullRequestReview(reviewer: "b", state: .changesRequested)
        #expect(SupermuxPullRequestDetail.reviewDecision(reviews: [approved, changes]) == .changesRequested)
        #expect(SupermuxPullRequestDetail.reviewDecision(reviews: [approved]) == .approved)
        #expect(SupermuxPullRequestDetail.reviewDecision(reviews: []) == .reviewRequired)
        #expect(SupermuxPullRequestDetail.reviewDecision(
            reviews: [SupermuxPullRequestReview(reviewer: "c", state: .commented)]
        ) == .reviewRequired)
    }

    @Test func latestReviewsKeepsVerdictOverLaterCommentAndSkipsAuthor() {
        let reviews = [
            SupermuxPullRequestReview(reviewer: "alice", state: .changesRequested),
            SupermuxPullRequestReview(reviewer: "alice", state: .commented),
            SupermuxPullRequestReview(reviewer: "bob", state: .commented),
            SupermuxPullRequestReview(reviewer: "bob", state: .approved),
            SupermuxPullRequestReview(reviewer: "me", state: .approved),
        ]
        let latest = SupermuxPullRequestDetail.latestReviews(reviews, excludingAuthor: "me")
        #expect(latest.map(\.reviewer) == ["alice", "bob"])
        #expect(latest.map(\.state) == [.changesRequested, .approved])
    }

    @Test func checkSummaryCountsOutcomes() {
        let checks = [
            SupermuxPullRequestCheck(name: "a", outcome: .success, url: nil),
            SupermuxPullRequestCheck(name: "b", outcome: .failure, url: nil),
            SupermuxPullRequestCheck(name: "c", outcome: .pending, url: nil),
            SupermuxPullRequestCheck(name: "d", outcome: .skipped, url: nil),
            SupermuxPullRequestCheck(name: "e", outcome: .success, url: nil),
        ]
        let summary = SupermuxPullRequestDetail.checkSummary(for: checks)
        #expect(summary.passed == 2)
        #expect(summary.failed == 1)
        #expect(summary.pending == 1)
        #expect(summary.skipped == 1)
        #expect(summary.total == 5)
    }

    @Test func checkOutcomeMapping() {
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "in_progress", conclusion: nil) == .pending)
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "queued", conclusion: nil) == .pending)
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "completed", conclusion: "success") == .success)
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "completed", conclusion: "skipped") == .skipped)
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "completed", conclusion: "neutral") == .skipped)
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "completed", conclusion: "failure") == .failure)
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "completed", conclusion: "timed_out") == .failure)
        #expect(SupermuxPullRequestDetailService.checkOutcome(status: "completed", conclusion: "cancelled") == .failure)
        #expect(SupermuxPullRequestDetailService.statusOutcome("success") == .success)
        #expect(SupermuxPullRequestDetailService.statusOutcome("pending") == .pending)
        #expect(SupermuxPullRequestDetailService.statusOutcome("error") == .failure)
    }

    @Test func mergeStatusMapping() {
        #expect(SupermuxPullRequestMergeStatus(detail: detail()).kind == .clean)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(mergeable: nil, mergeableState: nil)).kind == .computing)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(mergeable: true, mergeableState: "unknown")).kind == .computing)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(mergeable: false, mergeableState: "dirty")).kind == .conflicts)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(mergeable: true, mergeableState: "blocked")).kind == .blocked)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(mergeable: true, mergeableState: "behind")).kind == .behind)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(mergeable: true, mergeableState: "unstable")).kind == .unstable)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(state: .merged)).kind == .merged)
        #expect(SupermuxPullRequestMergeStatus(detail: detail(state: .closed, mergeable: false)).kind == .closed)
    }

    @Test func visibleButtonsMergesKnownAndFetched() {
        let known = SupermuxPullRequest(number: 5, status: .open, url: url("https://github.com/o/r/pull/5"))
        let fetched = [
            SupermuxPullRequestSummary(number: 5, title: "five", url: known.url, isDraft: false),
            SupermuxPullRequestSummary(number: 9, title: "nine", url: url("https://github.com/o/r/pull/9"), isDraft: true),
        ]
        // Fetched wins for the same number (it carries the title).
        let merged = SupermuxPullRequestViewerModel.visibleButtons(known: known, fetched: fetched)
        #expect(merged.map(\.number) == [5, 9])
        #expect(merged[0].title == "five")
        // A known PR the fetch missed is prepended.
        let extra = SupermuxPullRequestViewerModel.visibleButtons(known: known, fetched: [fetched[1]])
        #expect(extra.map(\.number) == [5, 9])
        // Only OPEN known PRs earn a button.
        let merged5 = SupermuxPullRequest(number: 5, status: .merged, url: known.url)
        #expect(SupermuxPullRequestViewerModel.visibleButtons(known: merged5, fetched: []).isEmpty)
        #expect(SupermuxPullRequestViewerModel.visibleButtons(known: nil, fetched: []).isEmpty)
    }

    @Test func openPullRequestsPathEncodesHeadFilter() {
        let path = SupermuxPullRequestDetailService.openPullRequestsPath(repositorySlug: "o/r", branch: "feat/x y")
        #expect(path == "repos/o/r/pulls?state=open&head=o:feat/x%20y&sort=updated&direction=desc&per_page=20")
        #expect(SupermuxPullRequestDetailService.openPullRequestsPath(repositorySlug: "broken", branch: "b") == nil)
    }

    // MARK: - REST mapping

    private static let pullJSON = """
    {"number": 42, "title": "Add thing", "body": "Does things", "state": "open", "draft": false,
     "html_url": "https://github.com/o/r/pull/42", "user": {"login": "me"},
     "head": {"ref": "feature", "sha": "abc123"}, "base": {"ref": "main", "sha": "def"},
     "created_at": "2026-09-01T10:00:00Z", "updated_at": "2026-09-02T10:00:00Z", "merged_at": null,
     "mergeable": true, "mergeable_state": "clean", "additions": 10, "deletions": 3, "changed_files": 2,
     "commits": 4, "comments": 1, "review_comments": 2,
     "labels": [{"name": "bug", "color": "d73a4a"}],
     "requested_reviewers": [{"login": "carol"}]}
    """

    @Test func detailComposesReviewsFilesAndChecks() async throws {
        let client = ScriptedGitHubClient(responses: [
            "repos/o/r/pulls/42": Self.pullJSON,
            "repos/o/r/pulls/42/reviews?per_page=100": """
            [{"user": {"login": "bob"}, "state": "APPROVED", "submitted_at": "2026-09-02T09:00:00Z"},
             {"user": {"login": "me"}, "state": "COMMENTED", "submitted_at": null}]
            """,
            "repos/o/r/pulls/42/files?per_page=100": """
            [{"filename": "a.swift", "status": "modified", "additions": 8, "deletions": 3},
             {"filename": "b.swift", "status": "added", "additions": 2, "deletions": 0}]
            """,
            "repos/o/r/commits/abc123/check-runs?per_page=100": """
            {"check_runs": [{"name": "build", "status": "completed", "conclusion": "success",
                             "html_url": "https://github.com/o/r/runs/1"},
                            {"name": "lint", "status": "in_progress", "conclusion": null}]}
            """,
            "repos/o/r/commits/abc123/status": """
            {"statuses": [{"context": "build", "state": "success", "target_url": null},
                          {"context": "vercel", "state": "failure", "target_url": "https://vercel.com/x"}]}
            """,
        ])
        let service = SupermuxPullRequestDetailService(client: client)
        let detail = try await service.detail(repositorySlug: "o/r", number: 42)

        #expect(detail.number == 42)
        #expect(detail.state == .open)
        #expect(detail.author == "me")
        #expect(detail.baseRef == "main")
        #expect(detail.headRef == "feature")
        #expect(detail.commentCount == 3)
        #expect(detail.labels.map(\.name) == ["bug"])
        #expect(detail.requestedReviewers == ["carol"])
        // The author's own comment is dropped; bob's approval remains.
        #expect(detail.reviews.map(\.reviewer) == ["bob"])
        #expect(detail.reviewDecision == .approved)
        #expect(detail.files.map(\.path) == ["a.swift", "b.swift"])
        #expect(detail.files[1].status == .added)
        // Check runs first; a legacy status with the same context is not duplicated.
        #expect(detail.checks.map(\.name) == ["build", "lint", "vercel"])
        #expect(detail.checks.map(\.outcome) == [.success, .pending, .failure])
        #expect(detail.checksError == nil)
        #expect(detail.updatedAt != nil)
    }

    @Test func detailRecordsChecksErrorWithoutFailing() async throws {
        let client = ScriptedGitHubClient(
            responses: ["repos/o/r/pulls/42": Self.pullJSON],
            failures: ["repos/o/r/commits/abc123/check-runs?per_page=100": .http(status: 403, message: "Resource not accessible")]
        )
        let detail = try await SupermuxPullRequestDetailService(client: client).detail(repositorySlug: "o/r", number: 42)
        #expect(detail.checks.isEmpty)
        #expect(detail.checksError?.contains("Resource not accessible") == true)
        #expect(detail.reviews.isEmpty)
        #expect(detail.files.isEmpty)
    }

    @Test func detailStateDistinguishesDraftMergedClosed() throws {
        func rest(_ state: String, draft: Bool, mergedAt: String?) throws -> RESTPullRequest {
            let merged = mergedAt.map { "\"\($0)\"" } ?? "null"
            let json = """
            {"number": 1, "title": "t", "state": "\(state)", "draft": \(draft), "html_url": "https://x",
             "head": {"ref": "h", "sha": "s"}, "merged_at": \(merged)}
            """
            return try JSONDecoder().decode(RESTPullRequest.self, from: Data(json.utf8))
        }
        #expect(SupermuxPullRequestDetailService.state(of: try rest("open", draft: true, mergedAt: nil)) == .draft)
        #expect(SupermuxPullRequestDetailService.state(of: try rest("open", draft: false, mergedAt: nil)) == .open)
        #expect(SupermuxPullRequestDetailService.state(of: try rest("closed", draft: false, mergedAt: nil)) == .closed)
        #expect(SupermuxPullRequestDetailService.state(of: try rest("closed", draft: false, mergedAt: "2026-09-01T00:00:00Z")) == .merged)
    }

    @Test func openPullRequestsFiltersToExactHeadRef() async throws {
        let path = SupermuxPullRequestDetailService.openPullRequestsPath(repositorySlug: "o/r", branch: "feature")!
        let client = ScriptedGitHubClient(responses: [
            path: """
            [{"number": 1, "title": "one", "state": "open", "html_url": "https://github.com/o/r/pull/1",
              "head": {"ref": "feature"}, "draft": true},
             {"number": 2, "title": "two", "state": "open", "html_url": "https://github.com/o/r/pull/2",
              "head": {"ref": "feature-2"}}]
            """,
        ])
        let list = try await SupermuxPullRequestDetailService(client: client).openPullRequests(repositorySlug: "o/r", branch: "feature")
        #expect(list.map(\.number) == [1])
        #expect(list[0].isDraft)
    }

    // MARK: - GitHub client

    @Test func tokenPrefersEnvironmentThenGH() async {
        let runner = FakeTokenRunner(token: "from-gh")
        let env = await SupermuxGitHubClient.resolveToken(environment: ["GH_TOKEN": " env-token "], runner: runner)
        #expect(env == "env-token")
        let gh = await SupermuxGitHubClient.resolveToken(environment: ["GH_TOKEN": "  "], runner: runner)
        #expect(gh == "from-gh")
        let none = await SupermuxGitHubClient.resolveToken(environment: [:], runner: FakeTokenRunner(token: ""))
        #expect(none == nil)
    }

    @Test func clientFailsClosedWithoutToken() async {
        let client = SupermuxGitHubClient(commandRunner: FakeTokenRunner(token: ""), session: .shared, environment: [:])
        await #expect(throws: SupermuxGitHubError.notAuthenticated) {
            _ = try await client.get(path: "repos/o/r/pulls/1")
        }
    }

    // MARK: - Viewer model

    @Test @MainActor func openLoadsListAndDetailOnceThenTogglesClosed() async throws {
        let provider = ScriptedProvider(summaries: [
            SupermuxPullRequestSummary(number: 7, title: "seven", url: url("https://github.com/o/r/pull/7"), isDraft: false),
        ], details: [7: detail(number: 7)])
        let model = SupermuxPullRequestViewerModel(provider: provider, slugResolver: { _ in ["o/r"] })
        model.setContext(directory: "/repo", branch: "feature")

        model.open(number: 7)
        #expect(model.selectedNumber == 7)
        #expect(model.isLoading)
        try await model.waitForLoad()
        #expect(!model.isLoading)
        #expect(model.selectedDetail?.number == 7)
        #expect(model.hasLoadedList)
        #expect(model.openPullRequests.map(\.number) == [7])
        #expect(model.errorMessage == nil)
        #expect(model.lastLoadedAt != nil)
        #expect(await provider.listCalls == 1)
        #expect(await provider.detailCalls == 1)

        // Clicking the selected button again returns to the changes list.
        model.open(number: 7)
        #expect(model.selectedNumber == nil)
        // Re-opening a cached PR fetches nothing.
        model.open(number: 7)
        #expect(!model.isLoading)
        #expect(model.selectedDetail?.number == 7)
        #expect(await provider.detailCalls == 1)

        // Refresh re-fetches both.
        model.refresh()
        try await model.waitForLoad()
        #expect(await provider.listCalls == 2)
        #expect(await provider.detailCalls == 2)
    }

    @Test @MainActor func contextChangeDropsCacheAndClosesViewer() async throws {
        let provider = ScriptedProvider(summaries: [], details: [3: detail(number: 3)])
        let model = SupermuxPullRequestViewerModel(provider: provider, slugResolver: { _ in ["o/r"] })
        model.setContext(directory: "/repo", branch: "a")
        model.open(number: 3)
        try await model.waitForLoad()
        #expect(model.selectedDetail != nil)

        model.setContext(directory: "/repo", branch: "b")
        #expect(model.selectedNumber == nil)
        #expect(model.details.isEmpty)
        #expect(!model.hasLoadedList)
        // Same context again is a no-op (no reset).
        model.open(number: 3)
        try await model.waitForLoad()
        model.setContext(directory: "/repo", branch: "b")
        #expect(model.selectedDetail?.number == 3)
    }

    @Test @MainActor func loadErrorIsSurfacedAndKeepsSelection() async throws {
        let provider = ScriptedProvider(summaries: [], details: [:], error: SupermuxGitHubError.http(status: 404, message: "Not Found"))
        let model = SupermuxPullRequestViewerModel(provider: provider, slugResolver: { _ in ["o/r"] })
        model.setContext(directory: "/repo", branch: "a")
        model.open(number: 9)
        try await model.waitForLoad()
        #expect(model.selectedNumber == 9)
        #expect(model.selectedDetail == nil)
        #expect(model.errorMessage?.contains("404") == true)
    }

    @Test @MainActor func nonGitHubDirectoryReportsError() async throws {
        let provider = ScriptedProvider(summaries: [], details: [:])
        let model = SupermuxPullRequestViewerModel(provider: provider, slugResolver: { _ in [] })
        model.setContext(directory: "/repo", branch: "a")
        model.open(number: 1)
        try await model.waitForLoad()
        #expect(model.errorMessage == SupermuxGitHubError.notAGitHubRepository.localizedDescription)
        #expect(await provider.listCalls == 0)
    }
}

// MARK: - Fakes

private struct ScriptedGitHubClient: SupermuxGitHubRequesting {
    let responses: [String: String]
    var failures: [String: SupermuxGitHubError] = [:]

    func get(path: String) async throws -> Data {
        if let failure = failures[path] { throw failure }
        guard let body = responses[path] else { throw SupermuxGitHubError.http(status: 404, message: "no stub for \(path)") }
        return Data(body.utf8)
    }
}

private struct FakeTokenRunner: CommandRunning {
    let token: String

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        CommandResult(stdout: token + "\n", stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
    }
}

private actor ScriptedProvider: SupermuxPullRequestDetailProviding {
    let summaries: [SupermuxPullRequestSummary]
    let details: [Int: SupermuxPullRequestDetail]
    let error: (any Error)?
    private(set) var listCalls = 0
    private(set) var detailCalls = 0

    init(summaries: [SupermuxPullRequestSummary], details: [Int: SupermuxPullRequestDetail], error: (any Error)? = nil) {
        self.summaries = summaries
        self.details = details
        self.error = error
    }

    func openPullRequests(repositorySlug: String, branch: String) async throws -> [SupermuxPullRequestSummary] {
        listCalls += 1
        if let error { throw error }
        return summaries
    }

    func detail(repositorySlug: String, number: Int) async throws -> SupermuxPullRequestDetail {
        detailCalls += 1
        if let error { throw error }
        guard let detail = details[number] else { throw SupermuxGitHubError.http(status: 404, message: "Not Found") }
        return detail
    }
}

extension SupermuxPullRequestViewerModel {
    /// Polls until the in-flight load settles (tests only).
    @MainActor
    func waitForLoad() async throws {
        for _ in 0..<200 where isLoading {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!isLoading)
    }
}

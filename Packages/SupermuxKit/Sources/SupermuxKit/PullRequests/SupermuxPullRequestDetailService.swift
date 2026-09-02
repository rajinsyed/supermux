public import Foundation

/// On-demand pull-request lookups for the Changes panel's PR viewer.
///
/// Abstracted so ``SupermuxPullRequestViewerModel`` can be unit-tested with a
/// scripted provider instead of GitHub.
public protocol SupermuxPullRequestDetailProviding: Sendable {
    /// The open pull requests in `repositorySlug` whose head is
    /// `headOwner:branch` (the head owner is the fork that pushed the branch,
    /// which for a fork-to-upstream PR differs from the slug's owner).
    func openPullRequests(
        repositorySlug: String, headOwner: String, branch: String
    ) async throws -> [SupermuxPullRequestSummary]
    /// The full detail for one pull request.
    func detail(repositorySlug: String, number: Int) async throws -> SupermuxPullRequestDetail
}

/// Fetches pull-request lists and details from the GitHub REST API.
///
/// Nothing here runs in the background: every call is triggered by a click
/// on a PR button or the viewer's refresh button. A detail load is five
/// requests (the PR, its reviews and files, and the head commit's check runs
/// and legacy statuses), issued concurrently. Reviews, files and checks are
/// best-effort: a failure there degrades to an empty section (checks record
/// the error) rather than failing the whole load, since fine-grained tokens
/// commonly lack `checks:read`.
public struct SupermuxPullRequestDetailService: SupermuxPullRequestDetailProviding {
    private let client: any SupermuxGitHubRequesting

    /// Creates the service.
    /// - Parameter client: The GitHub transport; defaults to the production client.
    public init(client: any SupermuxGitHubRequesting = SupermuxGitHubClient()) {
        self.client = client
    }

    public func openPullRequests(
        repositorySlug: String, headOwner: String, branch: String
    ) async throws -> [SupermuxPullRequestSummary] {
        guard let path = Self.openPullRequestsPath(repositorySlug: repositorySlug, headOwner: headOwner, branch: branch) else {
            throw SupermuxGitHubError.notAGitHubRepository
        }
        let items = try Self.decode([RESTPullRequest].self, from: try await client.get(path: path))
        return items
            .filter { $0.head.ref == branch }
            .compactMap { item in
                guard let url = URL(string: item.htmlURL) else { return nil }
                return SupermuxPullRequestSummary(
                    repositorySlug: repositorySlug,
                    number: item.number, title: item.title, url: url, isDraft: item.draft ?? false
                )
            }
    }

    public func detail(repositorySlug: String, number: Int) async throws -> SupermuxPullRequestDetail {
        let base = "repos/\(repositorySlug)/pulls/\(number)"
        async let pullRequestData = client.get(path: base)
        async let reviewsResult = attempt { try await client.get(path: "\(base)/reviews?per_page=100") }
        async let filesResult = attempt { try await client.get(path: "\(base)/files?per_page=100") }
        async let issueCommentsResult = attempt {
            try await client.get(path: "repos/\(repositorySlug)/issues/\(number)/comments?per_page=100")
        }
        async let reviewCommentsResult = attempt { try await client.get(path: "\(base)/comments?per_page=100") }

        let pullRequest = try Self.decode(RESTPullRequest.self, from: try await pullRequestData)
        let sha = pullRequest.head.sha ?? ""
        async let checkRunsResult = attempt {
            try await client.get(path: "repos/\(repositorySlug)/commits/\(sha)/check-runs?per_page=100")
        }
        async let statusResult = attempt {
            try await client.get(path: "repos/\(repositorySlug)/commits/\(sha)/status")
        }

        let reviews = (try? await reviewsResult.get())
            .flatMap { try? Self.decode([RESTReview].self, from: $0) } ?? []
        let files = (try? await filesResult.get())
            .flatMap { try? Self.decode([RESTFile].self, from: $0) } ?? []

        var checks: [SupermuxPullRequestCheck] = []
        var checksError: String?
        switch await checkRunsResult {
        case .success(let data):
            let runs = (try? Self.decode(RESTCheckRuns.self, from: data))?.checkRuns ?? []
            checks = runs.map(Self.check(from:))
        case .failure(let error):
            checksError = error.localizedDescription
        }
        if case .success(let data) = await statusResult,
           let combined = try? Self.decode(RESTCombinedStatus.self, from: data) {
            let runNames = Set(checks.map(\.name))
            checks += combined.statuses
                .map(Self.check(from:))
                .filter { !runNames.contains($0.name) }
        }

        let issueComments = (try? await issueCommentsResult.get())
            .flatMap { try? Self.decode([RESTComment].self, from: $0) } ?? []
        let reviewComments = (try? await reviewCommentsResult.get())
            .flatMap { try? Self.decode([RESTComment].self, from: $0) } ?? []

        return Self.detail(
            repositorySlug: repositorySlug,
            from: pullRequest,
            reviews: reviews,
            files: files,
            checks: checks,
            checksError: checksError,
            issueComments: issueComments,
            reviewComments: reviewComments
        )
    }

    // MARK: - Mapping (pure, testable)

    /// `pulls?state=open&head=headOwner:branch` for the slug, or `nil` for a
    /// malformed slug.
    static func openPullRequestsPath(repositorySlug: String, headOwner: String, branch: String) -> String? {
        let parts = repositorySlug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !headOwner.isEmpty else { return nil }
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "head", value: "\(headOwner):\(branch)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "20"),
        ]
        guard let encoded = query.percentEncodedQuery else { return nil }
        return "repos/\(repositorySlug)/pulls?\(encoded)"
    }

    static func detail(
        repositorySlug: String,
        from pullRequest: RESTPullRequest,
        reviews: [RESTReview],
        files: [RESTFile],
        checks: [SupermuxPullRequestCheck],
        checksError: String?,
        issueComments: [RESTComment] = [],
        reviewComments: [RESTComment] = []
    ) -> SupermuxPullRequestDetail {
        let author = pullRequest.user?.login ?? ""
        let allReviews = reviews.compactMap { review -> SupermuxPullRequestReview? in
            guard let login = review.user?.login else { return nil }
            return SupermuxPullRequestReview(
                reviewer: login,
                state: Self.reviewState(review.state),
                submittedAt: review.submittedAt.flatMap(Self.date(from:))
            )
        }
        return SupermuxPullRequestDetail(
            repositorySlug: repositorySlug,
            number: pullRequest.number,
            title: pullRequest.title,
            body: pullRequest.body ?? "",
            url: URL(string: pullRequest.htmlURL) ?? URL(string: "https://github.com")!,
            state: Self.state(of: pullRequest),
            author: author,
            baseRef: pullRequest.base?.ref ?? "",
            headRef: pullRequest.head.ref,
            headSHA: pullRequest.head.sha ?? "",
            createdAt: pullRequest.createdAt.flatMap(Self.date(from:)),
            updatedAt: pullRequest.updatedAt.flatMap(Self.date(from:)),
            additions: pullRequest.additions ?? 0,
            deletions: pullRequest.deletions ?? 0,
            changedFileCount: pullRequest.changedFiles ?? files.count,
            commitCount: pullRequest.commits ?? 0,
            commentCount: (pullRequest.comments ?? 0) + (pullRequest.reviewComments ?? 0),
            mergeable: pullRequest.mergeable,
            mergeableState: pullRequest.mergeableState,
            labels: (pullRequest.labels ?? []).map {
                SupermuxPullRequestLabel(name: $0.name, colorHex: $0.color ?? "")
            },
            requestedReviewers: (pullRequest.requestedReviewers ?? []).map(\.login),
            reviews: SupermuxPullRequestDetail.latestReviews(allReviews, excludingAuthor: author),
            checks: checks,
            checksError: checksError,
            files: files.map {
                SupermuxPullRequestFile(
                    path: $0.filename,
                    status: Self.fileStatus($0.status),
                    additions: $0.additions ?? 0,
                    deletions: $0.deletions ?? 0
                )
            },
            comments: Self.comments(issue: issueComments, reviews: reviews, inline: reviewComments)
        )
    }

    /// Merges the three comment sources into one oldest-first thread. Review
    /// summaries without a body (a bare approval) are not comments.
    static func comments(
        issue: [RESTComment], reviews: [RESTReview], inline: [RESTComment]
    ) -> [SupermuxPullRequestComment] {
        var comments: [SupermuxPullRequestComment] = []
        for comment in issue {
            comments.append(Self.comment(from: comment, kind: .conversation))
        }
        for review in reviews {
            guard let body = review.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
                  let id = review.id else { continue }
            comments.append(SupermuxPullRequestComment(
                id: id,
                kind: .review(Self.reviewState(review.state)),
                author: review.user?.login ?? "",
                body: body,
                createdAt: review.submittedAt.flatMap(Self.date(from:)),
                url: review.htmlURL.flatMap(URL.init(string:))
            ))
        }
        for comment in inline {
            comments.append(Self.comment(from: comment, kind: .inline(path: comment.path ?? "")))
        }
        return comments.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    private static func comment(from comment: RESTComment, kind: SupermuxPullRequestComment.Kind) -> SupermuxPullRequestComment {
        SupermuxPullRequestComment(
            id: comment.id,
            kind: kind,
            author: comment.user?.login ?? "",
            body: comment.body ?? "",
            createdAt: comment.createdAt.flatMap(Self.date(from:)),
            url: comment.htmlURL.flatMap(URL.init(string:))
        )
    }

    static func state(of pullRequest: RESTPullRequest) -> SupermuxPullRequestDetail.State {
        if pullRequest.mergedAt?.isEmpty == false { return .merged }
        if pullRequest.state.lowercased() == "closed" { return .closed }
        return pullRequest.draft == true ? .draft : .open
    }

    static func reviewState(_ raw: String) -> SupermuxPullRequestReview.State {
        switch raw.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "DISMISSED": return .dismissed
        case "PENDING": return .pending
        default: return .commented
        }
    }

    static func fileStatus(_ raw: String?) -> SupermuxPullRequestFile.Status {
        switch raw {
        case "added": return .added
        case "modified", "changed": return .modified
        case "removed": return .removed
        case "renamed": return .renamed
        default: return .other
        }
    }

    /// Collapses a check run's `status` + `conclusion` into an outcome:
    /// `in_progress` is running; `queued`/`waiting`/`requested`/`pending` are
    /// pending; only `completed` carries a conclusion.
    static func checkOutcome(status: String?, conclusion: String?) -> SupermuxPullRequestCheck.Outcome {
        if status == "in_progress" { return .running }
        guard status == "completed" else { return .pending }
        switch conclusion {
        case "success": return .success
        case "neutral", "skipped": return .skipped
        default: return .failure
        }
    }

    /// Maps a legacy commit status `state` (`pending`/`success`/`failure`/`error`).
    static func statusOutcome(_ state: String) -> SupermuxPullRequestCheck.Outcome {
        switch state {
        case "success": return .success
        case "pending": return .pending
        default: return .failure
        }
    }

    private static func check(from run: RESTCheckRun) -> SupermuxPullRequestCheck {
        SupermuxPullRequestCheck(
            name: run.name,
            outcome: checkOutcome(status: run.status, conclusion: run.conclusion),
            url: (run.htmlURL ?? run.detailsURL).flatMap(URL.init(string:))
        )
    }

    private static func check(from status: RESTStatus) -> SupermuxPullRequestCheck {
        SupermuxPullRequestCheck(
            name: status.context,
            outcome: statusOutcome(status.state),
            url: status.targetURL.flatMap(URL.init(string:))
        )
    }

    static func date(from string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SupermuxGitHubError.invalidResponse
        }
    }

    private func attempt(_ operation: @Sendable () async throws -> Data) async -> Result<Data, any Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - REST payloads (snake_case, decoded with explicit keys)

struct RESTPullRequest: Decodable, Sendable {
    struct Ref: Decodable, Sendable {
        let ref: String
        let sha: String?
    }
    struct User: Decodable, Sendable {
        let login: String
    }
    struct Label: Decodable, Sendable {
        let name: String
        let color: String?
    }

    let number: Int
    let title: String
    let body: String?
    let state: String
    let draft: Bool?
    let htmlURL: String
    let user: User?
    let head: Ref
    let base: Ref?
    let createdAt: String?
    let updatedAt: String?
    let mergedAt: String?
    let mergeable: Bool?
    let mergeableState: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let commits: Int?
    let comments: Int?
    let reviewComments: Int?
    let labels: [Label]?
    let requestedReviewers: [User]?

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, draft, user, head, base, mergeable, additions, deletions, commits, comments, labels
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
        case mergeableState = "mergeable_state"
        case changedFiles = "changed_files"
        case reviewComments = "review_comments"
        case requestedReviewers = "requested_reviewers"
    }
}

struct RESTReview: Decodable, Sendable {
    let id: Int?
    let user: RESTPullRequest.User?
    let state: String
    let body: String?
    let htmlURL: String?
    let submittedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, user, state, body
        case htmlURL = "html_url"
        case submittedAt = "submitted_at"
    }
}

/// An issue (conversation) comment or a pull-request review (inline) comment;
/// the two payloads share these fields, `path` being inline-only.
struct RESTComment: Decodable, Sendable {
    let id: Int
    let user: RESTPullRequest.User?
    let body: String?
    let path: String?
    let htmlURL: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, user, body, path
        case htmlURL = "html_url"
        case createdAt = "created_at"
    }
}

struct RESTFile: Decodable, Sendable {
    let filename: String
    let status: String?
    let additions: Int?
    let deletions: Int?
}

struct RESTCheckRuns: Decodable, Sendable {
    let checkRuns: [RESTCheckRun]

    enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

struct RESTCheckRun: Decodable, Sendable {
    let name: String
    let status: String?
    let conclusion: String?
    let htmlURL: String?
    let detailsURL: String?

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion
        case htmlURL = "html_url"
        case detailsURL = "details_url"
    }
}

struct RESTCombinedStatus: Decodable, Sendable {
    let statuses: [RESTStatus]
}

struct RESTStatus: Decodable, Sendable {
    let context: String
    let state: String
    let targetURL: String?

    enum CodingKeys: String, CodingKey {
        case context, state
        case targetURL = "target_url"
    }
}

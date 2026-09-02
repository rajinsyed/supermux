public import Foundation

/// One pull request for the current branch (open, merged or closed), reduced
/// to what the Changes panel's header buttons need. Produced by the on-demand list fetch in
/// ``SupermuxPullRequestDetailService``; the full ``SupermuxPullRequestDetail``
/// is loaded separately when a button is clicked.
public struct SupermuxPullRequestSummary: Hashable, Sendable, Identifiable {
    /// `owner/repo#number` — a number alone is ambiguous when a checkout has
    /// several GitHub remotes (a fork plus its upstream), which is exactly the
    /// setup where the same number names two unrelated PRs.
    public var id: String { "\(repositorySlug)#\(number)" }
    /// The `owner/repo` the PR lives in.
    public let repositorySlug: String
    /// The PR number (`#1234`).
    public let number: Int
    /// The PR title.
    public let title: String
    /// The PR's web URL.
    public let url: URL
    /// The PR's lifecycle state (drives the chip's color).
    public let status: SupermuxPullRequest.Status
    /// Whether the PR is a draft.
    public let isDraft: Bool

    /// Creates a summary.
    public init(
        repositorySlug: String, number: Int, title: String, url: URL,
        status: SupermuxPullRequest.Status = .open, isDraft: Bool
    ) {
        self.repositorySlug = repositorySlug
        self.number = number
        self.title = title
        self.url = url
        self.status = status
        self.isDraft = isDraft
    }

    /// Builds a summary from a badge cmux already resolved, taking the slug
    /// from the PR's URL (`https://github.com/owner/repo/pull/N`). `nil` when
    /// the URL is not a GitHub PR page.
    public init?(known pullRequest: SupermuxPullRequest) {
        guard let slug = Self.repositorySlug(fromPullRequestURL: pullRequest.url) else { return nil }
        self.init(
            repositorySlug: slug,
            number: pullRequest.number,
            title: pullRequest.title ?? "",
            url: pullRequest.url,
            status: pullRequest.status,
            isDraft: false
        )
    }

    /// `owner/repo` from a GitHub PR URL, or `nil`.
    public static func repositorySlug(fromPullRequestURL url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

/// One comment on a pull request: a conversation comment, a review summary,
/// or an inline review comment on a file.
public struct SupermuxPullRequestComment: Hashable, Sendable, Identifiable {
    /// Where the comment was left.
    public enum Kind: Hashable, Sendable {
        /// A comment on the PR conversation.
        case conversation
        /// The summary body of a review, with the review's state.
        case review(SupermuxPullRequestReview.State)
        /// An inline comment on `path`.
        case inline(path: String)
    }

    /// Source-qualified (`conversation:1`, `review:900`, `inline:2`): the
    /// three GitHub comment endpoints number independently, so a bare integer
    /// can collide once the sources are merged into one thread.
    public let id: String
    public let kind: Kind
    /// The commenter's login.
    public let author: String
    /// The comment's markdown source (shown as plain text).
    public let body: String
    public let createdAt: Date?
    /// The comment's web URL.
    public let url: URL?

    /// Creates a comment, deriving ``id`` from `kind` and GitHub's `id`.
    public init(id: Int, kind: Kind, author: String, body: String, createdAt: Date?, url: URL?) {
        self.id = "\(kind.idPrefix):\(id)"
        self.kind = kind
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

extension SupermuxPullRequestComment.Kind {
    /// The source segment of ``SupermuxPullRequestComment/id``.
    var idPrefix: String {
        switch self {
        case .conversation: return "conversation"
        case .review: return "review"
        case .inline: return "inline"
        }
    }
}

/// A label attached to a pull request.
public struct SupermuxPullRequestLabel: Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// The label text.
    public let name: String
    /// GitHub's six-digit hex color for the label (no `#`).
    public let colorHex: String

    /// Creates a label.
    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }
}

/// A reviewer's latest review on a pull request.
public struct SupermuxPullRequestReview: Hashable, Sendable, Identifiable {
    /// The state of a review, matching GitHub's review states.
    public enum State: String, Hashable, Sendable {
        case approved
        case changesRequested
        case commented
        case dismissed
        case pending
    }

    public var id: String { reviewer }
    /// The reviewer's login.
    public let reviewer: String
    /// The review's state.
    public let state: State
    /// When the review was submitted, when known.
    public let submittedAt: Date?

    /// Creates a review.
    public init(reviewer: String, state: State, submittedAt: Date? = nil) {
        self.reviewer = reviewer
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// One CI check (a check run or a legacy commit status) on a PR's head commit.
public struct SupermuxPullRequestCheck: Hashable, Sendable, Identifiable {
    /// A check's outcome, collapsed from GitHub's status/conclusion pairs.
    public enum Outcome: String, Hashable, Sendable {
        /// Queued, waiting, or requested but not started.
        case pending
        /// Currently running.
        case running
        /// Completed successfully.
        case success
        /// Failed, timed out, was cancelled, or needs action.
        case failure
        /// Completed without a verdict (neutral or skipped).
        case skipped
    }

    /// Unique per check (`run:<id>` for a check run, `status:<context>` for a
    /// legacy status). Matrix jobs and re-run workflows share a display name,
    /// so `name` alone would collide in a `ForEach`.
    public let id: String
    /// The check's display name.
    public let name: String
    /// The check's outcome.
    public let outcome: Outcome
    /// A link to the check's details page, when available.
    public let url: URL?

    /// Creates a check.
    public init(id: String, name: String, outcome: Outcome, url: URL?) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.url = url
    }
}

/// One file changed by a pull request.
public struct SupermuxPullRequestFile: Hashable, Sendable, Identifiable {
    /// How the file changed.
    public enum Status: String, Hashable, Sendable {
        case added
        case modified
        case removed
        case renamed
        case other
    }

    public var id: String { path }
    /// The file's path in the PR's head.
    public let path: String
    /// The kind of change.
    public let status: Status
    /// Lines added.
    public let additions: Int
    /// Lines deleted.
    public let deletions: Int

    /// Creates a changed file.
    public init(path: String, status: Status, additions: Int, deletions: Int) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// Everything the PR viewer shows for one pull request, fetched on demand by
/// ``SupermuxPullRequestDetailService`` and cached in
/// ``SupermuxPullRequestViewerModel``.
///
/// A pure value — the derived ``reviewDecision`` and ``checkSummary`` are
/// computed here so the rules are unit-testable without a network.
public struct SupermuxPullRequestDetail: Hashable, Sendable, Identifiable {
    /// The PR's lifecycle state, with draft split out of open.
    public enum State: String, Hashable, Sendable {
        case open
        case draft
        case merged
        case closed
    }

    /// The overall review verdict, following GitHub's review-decision rules.
    public enum ReviewDecision: String, Hashable, Sendable {
        /// At least one reviewer's latest review requests changes.
        case changesRequested
        /// At least one approval and no outstanding change requests.
        case approved
        /// Reviewers are requested or nobody has approved yet.
        case reviewRequired
    }

    /// Pass/fail/pending counts across the head commit's checks.
    public struct CheckSummary: Hashable, Sendable {
        public let passed: Int
        public let failed: Int
        /// Queued plus running.
        public let pending: Int
        public let skipped: Int

        /// Total number of checks.
        public var total: Int { passed + failed + pending + skipped }

        public init(passed: Int, failed: Int, pending: Int, skipped: Int) {
            self.passed = passed
            self.failed = failed
            self.pending = pending
            self.skipped = skipped
        }
    }

    public var id: String { "\(repositorySlug)#\(number)" }
    /// The `owner/repo` the PR lives in.
    public let repositorySlug: String
    public let number: Int
    public let title: String
    /// The PR description (markdown source, shown as plain text).
    public let body: String
    public let url: URL
    public let state: State
    /// The author's login.
    public let author: String
    public let baseRef: String
    public let headRef: String
    /// The head commit SHA (checks are keyed on it).
    public let headSHA: String
    public let createdAt: Date?
    public let updatedAt: Date?
    public let additions: Int
    public let deletions: Int
    public let changedFileCount: Int
    public let commitCount: Int
    /// Issue comments plus review comments.
    public let commentCount: Int
    /// GitHub's computed mergeability, `nil` while it is still being computed.
    public let mergeable: Bool?
    /// GitHub's `mergeable_state` (`clean`, `dirty`, `blocked`, `behind`,
    /// `unstable`, `unknown`, …), when reported.
    public let mergeableState: String?
    public let labels: [SupermuxPullRequestLabel]
    /// Logins of reviewers whose review is still requested.
    public let requestedReviewers: [String]
    /// Each reviewer's latest review (one entry per reviewer).
    public let reviews: [SupermuxPullRequestReview]
    public let checks: [SupermuxPullRequestCheck]
    /// Set when the checks could not be loaded (for example a token without
    /// `checks:read`); the checks section shows it instead of an empty list.
    public let checksError: String?
    public let files: [SupermuxPullRequestFile]
    /// Conversation comments, review summaries and inline review comments,
    /// oldest first.
    public let comments: [SupermuxPullRequestComment]

    public init(
        repositorySlug: String,
        number: Int,
        title: String,
        body: String,
        url: URL,
        state: State,
        author: String,
        baseRef: String,
        headRef: String,
        headSHA: String,
        createdAt: Date?,
        updatedAt: Date?,
        additions: Int,
        deletions: Int,
        changedFileCount: Int,
        commitCount: Int,
        commentCount: Int,
        mergeable: Bool?,
        mergeableState: String?,
        labels: [SupermuxPullRequestLabel],
        requestedReviewers: [String],
        reviews: [SupermuxPullRequestReview],
        checks: [SupermuxPullRequestCheck],
        checksError: String? = nil,
        files: [SupermuxPullRequestFile],
        comments: [SupermuxPullRequestComment] = []
    ) {
        self.repositorySlug = repositorySlug
        self.number = number
        self.title = title
        self.body = body
        self.url = url
        self.state = state
        self.author = author
        self.baseRef = baseRef
        self.headRef = headRef
        self.headSHA = headSHA
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFileCount = changedFileCount
        self.commitCount = commitCount
        self.commentCount = commentCount
        self.mergeable = mergeable
        self.mergeableState = mergeableState
        self.labels = labels
        self.requestedReviewers = requestedReviewers
        self.reviews = reviews
        self.checks = checks
        self.checksError = checksError
        self.files = files
        self.comments = comments
    }

    /// The review verdict derived from ``reviews`` and ``requestedReviewers``.
    public var reviewDecision: ReviewDecision {
        Self.reviewDecision(reviews: reviews)
    }

    /// Pass/fail/pending counts across ``checks``.
    public var checkSummary: CheckSummary {
        Self.checkSummary(for: checks)
    }

    /// The one comment count every label shows: the loaded thread's length
    /// (which includes review summaries with a body), falling back to
    /// GitHub's metadata count when the comment endpoints returned nothing.
    public var displayedCommentCount: Int {
        comments.isEmpty ? commentCount : comments.count
    }

    /// GitHub reports comments but none could be loaded (a failed or
    /// unauthorized comments request), as opposed to a PR nobody commented on.
    public var commentsAreUnavailable: Bool {
        comments.isEmpty && commentCount > 0
    }

    /// Whether ``state`` is open or draft (the PR can still change).
    public var isOpen: Bool {
        state == .open || state == .draft
    }

    /// GitHub's rule: any outstanding change request wins, then any approval,
    /// else a review is still required.
    public static func reviewDecision(reviews: [SupermuxPullRequestReview]) -> ReviewDecision {
        if reviews.contains(where: { $0.state == .changesRequested }) {
            return .changesRequested
        }
        if reviews.contains(where: { $0.state == .approved }) {
            return .approved
        }
        return .reviewRequired
    }

    /// Counts checks by outcome.
    public static func checkSummary(for checks: [SupermuxPullRequestCheck]) -> CheckSummary {
        var passed = 0, failed = 0, pending = 0, skipped = 0
        for check in checks {
            switch check.outcome {
            case .success: passed += 1
            case .failure: failed += 1
            case .pending, .running: pending += 1
            case .skipped: skipped += 1
            }
        }
        return CheckSummary(passed: passed, failed: failed, pending: pending, skipped: skipped)
    }

    /// Reduces a chronological review list to each reviewer's latest
    /// verdict-bearing review, the way GitHub computes the decision: a plain
    /// comment never overrides an earlier approval or change request, a
    /// dismissed review clears the reviewer's verdict, and the PR author's own
    /// reviews are ignored.
    /// - Parameters:
    ///   - reviews: Reviews in submission order (oldest first).
    ///   - author: The PR author's login, excluded from the result.
    /// - Returns: One review per reviewer, in first-seen order.
    public static func latestReviews(
        _ reviews: [SupermuxPullRequestReview],
        excludingAuthor author: String
    ) -> [SupermuxPullRequestReview] {
        var order: [String] = []
        var latest: [String: SupermuxPullRequestReview] = [:]
        for review in reviews where review.reviewer != author {
            switch review.state {
            case .approved, .changesRequested:
                if latest[review.reviewer] == nil { order.append(review.reviewer) }
                latest[review.reviewer] = review
            case .dismissed:
                if latest[review.reviewer] == nil { order.append(review.reviewer) }
                latest[review.reviewer] = review
            case .commented, .pending:
                // A comment only counts when the reviewer has no verdict yet.
                if latest[review.reviewer] == nil {
                    order.append(review.reviewer)
                    latest[review.reviewer] = review
                }
            }
        }
        return order.compactMap { latest[$0] }
    }
}

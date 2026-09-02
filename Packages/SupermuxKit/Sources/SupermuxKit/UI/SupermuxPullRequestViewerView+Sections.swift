import SwiftUI

/// The reviews, checks, labels, description and files sections of
/// ``SupermuxPullRequestViewerView``. Split out to keep the main file short;
/// every builder takes a value snapshot and renders rows without touching
/// the model.
extension SupermuxPullRequestViewerView {

    // MARK: - Reviews

    @ViewBuilder
    func reviewsSection(_ detail: SupermuxPullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(String(localized: "supermux.pullRequest.viewer.reviews", defaultValue: "Reviews"))
            reviewDecisionRow(detail.reviewDecision)
            ForEach(detail.reviews) { review in
                reviewRow(login: review.reviewer, symbol: review.state.symbol, tint: review.state.tint, text: review.state.label)
            }
            ForEach(detail.requestedReviewers, id: \.self) { login in
                reviewRow(
                    login: login,
                    symbol: "clock",
                    tint: .secondary,
                    text: String(localized: "supermux.pullRequest.review.requested", defaultValue: "Requested")
                )
            }
        }
    }

    private func reviewDecisionRow(_ decision: SupermuxPullRequestDetail.ReviewDecision) -> some View {
        HStack(spacing: 4) {
            Image(systemName: decision.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(decision.tint)
            Text(decision.label)
                .font(.system(size: 10.5, weight: .medium))
        }
    }

    private func reviewRow(login: String, symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(login)
                .font(.system(size: 10.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 2)
    }

    // MARK: - Checks

    @ViewBuilder
    func checksSection(_ detail: SupermuxPullRequestDetail) -> some View {
        let summary = detail.checkSummary
        VStack(alignment: .leading, spacing: 4) {
            let pendingCount = summary.pending
            sectionTitle(
                String(localized: "supermux.pullRequest.viewer.checks", defaultValue: "Checks"),
                trailing: summary.total > 0 ? "\(summary.passed)/\(summary.total)" : nil,
                note: pendingCount > 0
                    ? String(localized: "supermux.pullRequest.checks.inProgress", defaultValue: "\(pendingCount) in progress")
                    : nil
            )
            if let error = detail.checksError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            } else if detail.checks.isEmpty {
                Text(String(localized: "supermux.pullRequest.checks.none", defaultValue: "No checks reported"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(detail.checks) { check in
                    checkRow(check)
                }
            }
        }
    }

    private func checkRow(_ check: SupermuxPullRequestCheck) -> some View {
        HStack(spacing: 5) {
            if check.outcome == .running {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: check.outcome.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(check.outcome.tint)
                    .frame(width: 12)
            }
            Text(check.name)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let stateLabel = check.outcome.inProgressLabel {
                Text(stateLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            }
            if let url = check.url {
                Button {
                    onOpenURL(url)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "supermux.pullRequest.check.open.help", defaultValue: "Open check details"))
            }
        }
        .padding(.leading, 2)
    }

    // MARK: - Labels

    func labelsRow(_ labels: [SupermuxPullRequestLabel]) -> some View {
        SupermuxFlowLayout(spacing: 4) {
            ForEach(labels) { label in
                let tint = Color(hex: label.colorHex) ?? .secondary
                Text(label.name)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.16)))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Description

    @ViewBuilder
    func descriptionSection(_ detail: SupermuxPullRequestDetail) -> some View {
        let body = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(String(localized: "supermux.pullRequest.viewer.description", defaultValue: "Description"))
            if body.isEmpty {
                Text(String(localized: "supermux.pullRequest.description.empty", defaultValue: "No description provided"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text(body)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary)
                    .lineLimit(isBodyExpanded ? nil : Self.collapsedBodyLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if Self.needsExpansion(body) {
                    Button(isBodyExpanded
                        ? String(localized: "supermux.pullRequest.description.less", defaultValue: "Show less")
                        : String(localized: "supermux.pullRequest.description.more", defaultValue: "Show more")
                    ) {
                        isBodyExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    static let collapsedBodyLines = 8

    /// Whether a body is long enough to warrant the Show more toggle.
    static func needsExpansion(_ body: String) -> Bool {
        body.split(separator: "\n", omittingEmptySubsequences: false).count > collapsedBodyLines || body.count > 600
    }

    // MARK: - Files

    @ViewBuilder
    func filesSection(_ detail: SupermuxPullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(
                String(localized: "supermux.pullRequest.viewer.filesChanged", defaultValue: "Files changed"),
                trailing: detail.changedFileCount > 0 ? "\(detail.changedFileCount)" : nil
            )
            if detail.files.isEmpty {
                Text(String(localized: "supermux.pullRequest.files.none", defaultValue: "No file list available"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(detail.files) { file in
                    fileRow(file)
                }
                if detail.files.count < detail.changedFileCount {
                    Text(String(
                        localized: "supermux.pullRequest.files.truncated",
                        defaultValue: "Showing first \(detail.files.count) files"
                    ))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fileRow(_ file: SupermuxPullRequestFile) -> some View {
        HStack(spacing: 5) {
            Text(file.status.letter)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(file.status.tint)
                .frame(width: 12)
            Text(file.path)
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.path)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
            .font(.system(size: 9.5, design: .monospaced))
        }
        .padding(.leading, 2)
    }
}

// MARK: - Comments

extension SupermuxPullRequestViewerView {
    static let collapsedCommentLines = 6

    @ViewBuilder
    func commentsSection(_ detail: SupermuxPullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(
                String(localized: "supermux.pullRequest.viewer.commentsSection", defaultValue: "Comments"),
                trailing: detail.comments.isEmpty ? nil : "\(detail.comments.count)"
            )
            if detail.comments.isEmpty {
                Text(String(localized: "supermux.pullRequest.comments.none", defaultValue: "No comments yet"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(detail.comments) { comment in
                    commentRow(comment)
                }
            }
        }
    }

    private func commentRow(_ comment: SupermuxPullRequestComment) -> some View {
        let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExpanded = expandedCommentIds.contains(comment.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: comment.kind.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(comment.kind.tint)
                Text(comment.author)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                if let label = comment.kind.label {
                    Text(label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(comment.kind.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let createdAt = comment.createdAt {
                    Text(createdAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let url = comment.url {
                    Button {
                        onOpenURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "supermux.pullRequest.comment.open.help", defaultValue: "Open comment on GitHub"))
                }
            }
            if case .inline(let path) = comment.kind, !path.isEmpty {
                Text(path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(body)
                .font(.system(size: 10.5))
                .lineLimit(isExpanded ? nil : Self.collapsedCommentLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if Self.commentNeedsExpansion(body) {
                Button(isExpanded
                    ? String(localized: "supermux.pullRequest.description.less", defaultValue: "Show less")
                    : String(localized: "supermux.pullRequest.description.more", defaultValue: "Show more")
                ) {
                    if isExpanded {
                        expandedCommentIds.remove(comment.id)
                    } else {
                        expandedCommentIds.insert(comment.id)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
    }

    static func commentNeedsExpansion(_ body: String) -> Bool {
        body.split(separator: "\n", omittingEmptySubsequences: false).count > collapsedCommentLines || body.count > 400
    }
}

extension SupermuxPullRequestComment.Kind {
    var symbol: String {
        switch self {
        case .conversation: return "bubble.left"
        case .review(let state): return state.symbol
        case .inline: return "text.bubble"
        }
    }

    var tint: Color {
        switch self {
        case .conversation, .inline: return .secondary
        case .review(let state): return state.tint
        }
    }

    /// A short tag after the author: the review verdict for review
    /// summaries, "on a file" for inline comments, nothing for conversation.
    var label: String? {
        switch self {
        case .conversation: return nil
        case .review(let state): return state.label
        case .inline: return String(localized: "supermux.pullRequest.comment.inline", defaultValue: "on a file")
        }
    }
}

// MARK: - Presentation helpers

extension SupermuxPullRequestReview.State {
    var symbol: String {
        switch self {
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "xmark.circle.fill"
        case .commented: return "bubble.left"
        case .dismissed: return "minus.circle"
        case .pending: return "clock"
        }
    }

    var tint: Color {
        switch self {
        case .approved: return SupermuxPullRequest.Status.open.supermuxTint
        case .changesRequested: return SupermuxPullRequest.Status.closed.supermuxTint
        case .commented, .dismissed, .pending: return .secondary
        }
    }

    var label: String {
        switch self {
        case .approved: return String(localized: "supermux.pullRequest.review.approved", defaultValue: "Approved")
        case .changesRequested:
            return String(localized: "supermux.pullRequest.review.changesRequested", defaultValue: "Changes requested")
        case .commented: return String(localized: "supermux.pullRequest.review.commented", defaultValue: "Commented")
        case .dismissed: return String(localized: "supermux.pullRequest.review.dismissed", defaultValue: "Dismissed")
        case .pending: return String(localized: "supermux.pullRequest.review.pending", defaultValue: "Pending")
        }
    }
}

extension SupermuxPullRequestDetail.ReviewDecision {
    var symbol: String {
        switch self {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "exclamationmark.circle.fill"
        case .reviewRequired: return "person.crop.circle.badge.clock"
        }
    }

    var tint: Color {
        switch self {
        case .approved: return SupermuxPullRequest.Status.open.supermuxTint
        case .changesRequested: return SupermuxPullRequest.Status.closed.supermuxTint
        case .reviewRequired: return .secondary
        }
    }

    var label: String {
        switch self {
        case .approved:
            return String(localized: "supermux.pullRequest.reviewDecision.approved", defaultValue: "Approved")
        case .changesRequested:
            return String(localized: "supermux.pullRequest.reviewDecision.changesRequested", defaultValue: "Changes requested")
        case .reviewRequired:
            return String(localized: "supermux.pullRequest.reviewDecision.required", defaultValue: "Review required")
        }
    }
}

extension SupermuxPullRequestCheck.Outcome {
    var symbol: String {
        switch self {
        case .pending: return "clock"
        case .running: return "circle.dotted"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .running: return .orange
        case .success: return SupermuxPullRequest.Status.open.supermuxTint
        case .failure: return SupermuxPullRequest.Status.closed.supermuxTint
        case .skipped: return .secondary
        }
    }

    /// Trailing state word for checks that have not finished; `nil` otherwise.
    var inProgressLabel: String? {
        switch self {
        case .pending: return String(localized: "supermux.pullRequest.check.queued", defaultValue: "Queued")
        case .running: return String(localized: "supermux.pullRequest.check.running", defaultValue: "Running")
        case .success, .failure, .skipped: return nil
        }
    }
}

extension SupermuxPullRequestFile.Status {
    var letter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .removed: return "D"
        case .renamed: return "R"
        case .other: return "•"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .modified: return .orange
        case .removed: return .red
        case .renamed: return .blue
        case .other: return .secondary
        }
    }
}

extension Color {
    /// Parses GitHub's six-digit hex label color (no `#`).
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// A minimal wrapping row layout for label chips.
struct SupermuxFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

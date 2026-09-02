public import SwiftUI

/// The pull-request view shown inside the Changes panel when a header PR
/// button is clicked: title and state, author / base ← head, size stats,
/// mergeability, reviews, CI checks, labels, description and changed files,
/// plus a top bar with Back, Open on GitHub and Refresh.
///
/// Reads ``SupermuxPullRequestViewerModel`` (the snapshot boundary is this
/// view; rows below receive values only). Nothing here starts a load — the
/// model loads on `open`/`refresh` only.
public struct SupermuxPullRequestViewerView: View {
    @Bindable var model: SupermuxPullRequestViewerModel
    /// Internal so the sections extension can open check links.
    let onOpenURL: (URL) -> Void

    @State var isBodyExpanded = false
    @State var expandedCommentIds: Set<String> = []

    /// Creates the viewer.
    /// - Parameters:
    ///   - model: The viewer model (owned by the host, shared with the header).
    ///   - onOpenURL: Opens a URL in the browser (PR page, check details).
    public init(model: SupermuxPullRequestViewerModel, onOpenURL: @escaping (URL) -> Void) {
        self.model = model
        self.onOpenURL = onOpenURL
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let detail = model.selectedDetail {
                content(detail)
            } else if model.isLoading {
                loadingState
            } else {
                emptyState
            }
        }
        .onChange(of: model.selected) { _, _ in
            isBodyExpanded = false
            expandedCommentIds = []
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Button {
                model.close()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text(String(localized: "supermux.pullRequest.viewer.back", defaultValue: "Changes"))
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "supermux.pullRequest.viewer.back.help", defaultValue: "Back to changes"))

            if let selected = model.selected {
                Text("\(selected.repositorySlug)#\(selected.number)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if let detail = model.selectedDetail {
                toolbarButton(
                    "arrow.up.right.square",
                    help: String(localized: "supermux.pullRequest.viewer.openGitHub.help", defaultValue: "Open on GitHub")
                ) {
                    onOpenURL(detail.url)
                }
            }
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                toolbarButton(
                    "arrow.clockwise",
                    help: String(localized: "supermux.pullRequest.viewer.refresh.help", defaultValue: "Refresh pull request")
                ) {
                    model.refresh()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Content

    private func content(_ detail: SupermuxPullRequestDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                titleBlock(detail)
                statsRow(detail)
                if let error = model.errorMessage {
                    errorCaption(error)
                }
                mergeStatusRow(detail)
                reviewsSection(detail)
                checksSection(detail)
                if !detail.labels.isEmpty {
                    labelsRow(detail.labels)
                }
                descriptionSection(detail)
                filesSection(detail)
                commentsSection(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func titleBlock(_ detail: SupermuxPullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                statePill(detail.state)
                Text(detail.title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Text(detail.author)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.quaternary)
                Text(detail.baseRef)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.left")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(detail.headRef)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            if let updatedAt = detail.updatedAt {
                let relative = updatedAt.formatted(.relative(presentation: .named))
                Text(String(localized: "supermux.pullRequest.viewer.updated", defaultValue: "Updated \(relative)"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func statePill(_ state: SupermuxPullRequestDetail.State) -> some View {
        Text(state.supermuxLabel)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(state.supermuxTint))
            .padding(.top, 1)
    }

    private func statsRow(_ detail: SupermuxPullRequestDetail) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Text("+\(detail.additions)").foregroundStyle(.green)
                Text("−\(detail.deletions)").foregroundStyle(.red)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            stat("doc", String(localized: "supermux.pullRequest.viewer.files", defaultValue: "\(detail.changedFileCount) files"))
            stat("checkmark.circle", String(localized: "supermux.pullRequest.viewer.commits", defaultValue: "\(detail.commitCount) commits"))
            stat("bubble.left", String(localized: "supermux.pullRequest.viewer.comments", defaultValue: "\(detail.displayedCommentCount) comments"))
        }
        .lineLimit(1)
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Merge status

    private func mergeStatusRow(_ detail: SupermuxPullRequestDetail) -> some View {
        let status = SupermuxPullRequestMergeStatus(detail: detail)
        return HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(status.tint)
            Text(status.label)
                .font(.system(size: 10.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(status.tint.opacity(0.10)))
    }

    // MARK: - Shared bits

    /// A section header: uppercase title, optional count capsule, optional
    /// orange note (e.g. "1 in progress") — all leading-aligned.
    func sectionTitle(_ title: String, trailing: String? = nil, note: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if let note {
                Text(note)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    func errorCaption(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10.5))
            .foregroundStyle(.red)
            .lineLimit(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingState: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "supermux.pullRequest.viewer.loading", defaultValue: "Loading pull request…"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if let error = model.errorMessage {
                errorCaption(error)
                    .multilineTextAlignment(.center)
            } else {
                Text(String(localized: "supermux.pullRequest.viewer.empty", defaultValue: "Pull request not loaded"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Button(String(localized: "supermux.pullRequest.viewer.retry", defaultValue: "Retry")) {
                model.refresh()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

/// The mergeability line: GitHub's `mergeable` + `mergeable_state`, folded
/// into one symbol, tint and label. Pure so the mapping is testable.
struct SupermuxPullRequestMergeStatus: Equatable {
    enum Kind: Equatable { case merged, closed, computing, conflicts, blocked, behind, unstable, clean }

    let kind: Kind

    init(detail: SupermuxPullRequestDetail) {
        switch detail.state {
        case .merged:
            kind = .merged
        case .closed:
            kind = .closed
        case .open, .draft:
            switch (detail.mergeable, detail.mergeableState) {
            case (nil, _), (_, "unknown"):
                kind = .computing
            case (false, _), (_, "dirty"):
                kind = .conflicts
            case (_, "blocked"):
                kind = .blocked
            case (_, "behind"):
                kind = .behind
            case (_, "unstable"):
                kind = .unstable
            default:
                kind = .clean
            }
        }
    }

    var symbol: String {
        switch kind {
        case .merged: return "checkmark.circle.fill"
        case .closed: return "xmark.circle"
        case .computing: return "clock"
        case .conflicts: return "exclamationmark.triangle.fill"
        case .blocked: return "hand.raised.fill"
        case .behind: return "arrow.down.circle"
        case .unstable: return "exclamationmark.circle"
        case .clean: return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .merged: return SupermuxPullRequest.Status.merged.supermuxTint
        case .closed: return .secondary
        case .computing: return .secondary
        case .conflicts, .blocked: return SupermuxPullRequest.Status.closed.supermuxTint
        case .behind, .unstable: return .orange
        case .clean: return SupermuxPullRequest.Status.open.supermuxTint
        }
    }

    var label: String {
        switch kind {
        case .merged:
            return String(localized: "supermux.pullRequest.merge.merged", defaultValue: "Merged")
        case .closed:
            return String(localized: "supermux.pullRequest.merge.closed", defaultValue: "Closed without merging")
        case .computing:
            return String(localized: "supermux.pullRequest.merge.computing", defaultValue: "Checking mergeability…")
        case .conflicts:
            return String(localized: "supermux.pullRequest.merge.conflicts", defaultValue: "Merge conflicts")
        case .blocked:
            return String(localized: "supermux.pullRequest.merge.blocked", defaultValue: "Merging is blocked")
        case .behind:
            return String(localized: "supermux.pullRequest.merge.behind", defaultValue: "Behind base branch")
        case .unstable:
            return String(localized: "supermux.pullRequest.merge.unstable", defaultValue: "Mergeable, checks failing")
        case .clean:
            return String(localized: "supermux.pullRequest.merge.clean", defaultValue: "Ready to merge")
        }
    }
}

extension SupermuxPullRequestDetail.State {
    var supermuxTint: Color {
        switch self {
        case .open: return SupermuxPullRequest.Status.open.supermuxTint
        case .draft: return .gray
        case .merged: return SupermuxPullRequest.Status.merged.supermuxTint
        case .closed: return SupermuxPullRequest.Status.closed.supermuxTint
        }
    }

    var supermuxLabel: String {
        switch self {
        case .open: return String(localized: "supermux.pullRequest.state.open", defaultValue: "Open")
        case .draft: return String(localized: "supermux.pullRequest.state.draft", defaultValue: "Draft")
        case .merged: return String(localized: "supermux.pullRequest.state.merged", defaultValue: "Merged")
        case .closed: return String(localized: "supermux.pullRequest.state.closed", defaultValue: "Closed")
        }
    }
}

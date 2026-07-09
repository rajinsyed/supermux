import SwiftUI

/// The Worktrees section of the project detail screen: loading/empty states,
/// one row per worktree, and a New Worktree button in the header.
///
/// Renders exclusively from immutable ``SupermuxWorktreeRowSnapshot`` values
/// plus closures — no store reference crosses the `List` boundary, per the
/// repo's snapshot-boundary rule.
struct SupermuxWorktreesSection: View {
    let hasLoaded: Bool
    let rows: [SupermuxWorktreeRowSnapshot]
    let newWorktree: @MainActor () -> Void
    let openWorktree: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void
    let requestRemoval: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void

    var body: some View {
        Section {
            if !hasLoaded {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(
                        localized: "supermux.worktrees.loading",
                        defaultValue: "Loading worktrees…",
                        bundle: .module
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } else if rows.isEmpty {
                Text(String(
                    localized: "supermux.worktrees.empty",
                    defaultValue: "No worktrees yet",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    SupermuxWorktreeMobileRow(
                        row: row,
                        openWorktree: openWorktree,
                        requestRemoval: requestRemoval
                    )
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(String(
                    localized: "supermux.projects.detail.worktreesTitle",
                    defaultValue: "Worktrees",
                    bundle: .module
                ))
                Spacer(minLength: 0)
                Button(action: newWorktree) {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(
                    localized: "supermux.worktrees.new",
                    defaultValue: "New Worktree",
                    bundle: .module
                ))
                .accessibilityIdentifier("SupermuxNewWorktreeButton")
            }
        }
    }
}

/// One worktree row: branch name, dirty indicator, PR badge, and either a
/// workspace link (open worktrees) or an open action (unopened ones).
/// Swipe-to-delete starts the removal flow (destructive confirm upstream).
struct SupermuxWorktreeMobileRow: View {
    let row: SupermuxWorktreeRowSnapshot
    let openWorktree: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void
    let requestRemoval: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void

    var body: some View {
        Button {
            openWorktree(row)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(row.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(String(
                            localized: "supermux.worktrees.row.dirty",
                            defaultValue: "Uncommitted changes",
                            bundle: .module
                        ))
                }
                Spacer(minLength: 4)
                if let pullRequest = row.pullRequest {
                    SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
                }
                if row.isOpen {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestRemoval(row)
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.worktrees.remove.title",
                        defaultValue: "Remove Worktree",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        .accessibilityLabel(row.displayName)
        .accessibilityValue(row.isOpen
            ? String(
                localized: "supermux.worktrees.row.openWorkspace",
                defaultValue: "Open workspace",
                bundle: .module
            )
            : "")
        .accessibilityIdentifier("SupermuxWorktreeRow-\(row.id)")
    }
}

/// The compact, tappable PR badge: number tinted by the PR's lifecycle state
/// — the same green/purple/red the desktop `SupermuxPullRequestBadge` uses.
/// Number + state only (the Mac has no PR-title source); tapping opens the
/// PR's URL locally on the phone.
struct SupermuxMobilePullRequestBadge: View {
    let pullRequest: SupermuxPullRequestBadgeSnapshot

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = pullRequest.url {
                openURL(url)
            }
        } label: {
            HStack(spacing: 2) {
                stateIcon
                Text(verbatim: "#\(pullRequest.number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
            // Stale badges (kept after repeated mac probe failures) dim to
            // 50% — the mac badge's exact treatment.
            .opacity(pullRequest.isStale ? 0.5 : 1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.16)))
        }
        .buttonStyle(.borderless)
        .disabled(pullRequest.url == nil)
        .accessibilityLabel(accessibilityLabel)
    }

    /// State tint mirroring the desktop badge: green open, purple merged,
    /// red closed; neutral for unknown future states.
    private var tint: Color {
        switch pullRequest.state {
        case .open: Color(red: 0.247, green: 0.722, blue: 0.314)
        case .merged: Color(red: 0.639, green: 0.443, blue: 0.969)
        case .closed: Color(red: 0.973, green: 0.318, blue: 0.286)
        case .unknown: Color.secondary
        }
    }

    /// The state icon: the Mac's real git-pull-request glyph for open/merged
    /// (`SupermuxMobilePullRequestGlyph`, same path geometry as the sidebar
    /// badge) and the same SF-symbol fallbacks for closed/unknown. Inherits
    /// the surrounding `foregroundStyle`, so the state tint colors it.
    @ViewBuilder
    private var stateIcon: some View {
        switch pullRequest.state {
        case .open:
            SupermuxMobilePullRequestGlyph(kind: .open, size: 12)
        case .merged:
            SupermuxMobilePullRequestGlyph(kind: .merged, size: 12)
        case .closed:
            Image(systemName: "xmark.circle")
                .font(.caption2.weight(.semibold))
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(.caption2.weight(.semibold))
        }
    }

    private var stateWord: String {
        switch pullRequest.state {
        case .open:
            String(localized: "supermux.pullRequest.status.open", defaultValue: "open", bundle: .module)
        case .merged:
            String(localized: "supermux.pullRequest.status.merged", defaultValue: "merged", bundle: .module)
        case .closed:
            String(localized: "supermux.pullRequest.status.closed", defaultValue: "closed", bundle: .module)
        case .unknown:
            String(localized: "supermux.pullRequest.status.unknown", defaultValue: "unknown", bundle: .module)
        }
    }

    private var accessibilityLabel: String {
        String(
            localized: "supermux.pullRequest.accessibility",
            defaultValue: "Pull request #\(pullRequest.number), \(stateWord)",
            bundle: .module
        )
    }
}

import SwiftUI

/// Collapsible commit-list section for the Changes panel, used for both the
/// outgoing (Unpushed, ↑) and incoming (↓) feeds.
///
/// A disclosure header — a direction arrow, a title, and a count badge — that,
/// when expanded, lists commits and offers a "Show more" affordance when more
/// exist. Receives only immutable value snapshots plus action closures — never
/// the changes model — so it sits safely below the panel's `LazyVStack`
/// snapshot boundary.
struct SupermuxCommitHistorySection: View {
    /// Section title (e.g. "Unpushed", "Incoming").
    let title: String
    /// SF Symbol for the direction arrow (e.g. `arrow.up`, `arrow.down`).
    let directionSymbol: String
    /// Authoritative commit count for the header badge, shown collapsed or
    /// expanded (the loaded ``commits`` may lag or be paged below this).
    let count: Int
    let isExpanded: Bool
    let commits: [SupermuxGitCommit]
    let hasMore: Bool
    let isLoading: Bool
    /// Text shown when expanded with no commits.
    let emptyText: String
    /// Help shown on the header while collapsed (the expand affordance).
    let expandHelp: String
    /// Help shown on the header while expanded (the collapse affordance).
    let collapseHelp: String
    let onToggle: () -> Void
    let onLoadMore: () -> Void

    @ViewBuilder
    var body: some View {
        disclosureHeader
        if isExpanded {
            if commits.isEmpty {
                placeholder
            } else {
                ForEach(commits) { SupermuxCommitRowView(commit: $0) }
                if hasMore {
                    showMoreButton
                }
            }
        }
    }

    private var disclosureHeader: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: directionSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? collapseHelp : expandHelp)
        .padding(.horizontal, 5)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var placeholder: some View {
        // Show "Loading…" not just while a read is in flight but whenever the
        // authoritative `count` says commits exist yet the paged list has not
        // landed — otherwise the badge ("3") and the body ("No commits") would
        // momentarily contradict each other. "No commits" shows only once the
        // count itself is zero.
        Text((isLoading || count > 0)
            ? String(localized: "supermux.changes.commitHistory.loading", defaultValue: "Loading…")
            : emptyText)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
    }

    private var showMoreButton: some View {
        Button(action: onLoadMore) {
            Text(String(localized: "supermux.changes.unpushed.showMore", defaultValue: "Show more"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

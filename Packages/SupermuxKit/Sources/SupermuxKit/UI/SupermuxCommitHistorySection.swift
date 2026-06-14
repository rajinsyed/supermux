import SwiftUI

/// Collapsible unpushed-commits section for the Changes panel.
///
/// A disclosure header that, when expanded, lists the local commits not yet on
/// the remote and offers a "Show more" affordance when more exist. Receives
/// only immutable value snapshots plus action closures — never the changes
/// model — so it sits safely below the panel's `LazyVStack` snapshot boundary.
struct SupermuxCommitHistorySection: View {
    let isExpanded: Bool
    let commits: [SupermuxGitCommit]
    let hasMore: Bool
    let isLoading: Bool
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
                Text(String(localized: "supermux.changes.unpushed.title", defaultValue: "Unpushed"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if isExpanded, !commits.isEmpty {
                    Text(hasMore ? "\(commits.count)+" : "\(commits.count)")
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
        .help(isExpanded
            ? String(localized: "supermux.changes.unpushed.collapse.help", defaultValue: "Hide unpushed commits")
            : String(localized: "supermux.changes.unpushed.expand.help", defaultValue: "Show unpushed commits"))
        .padding(.horizontal, 5)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var placeholder: some View {
        Text(isLoading
            ? String(localized: "supermux.changes.unpushed.loading", defaultValue: "Loading…")
            : String(localized: "supermux.changes.unpushed.empty", defaultValue: "No unpushed commits"))
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

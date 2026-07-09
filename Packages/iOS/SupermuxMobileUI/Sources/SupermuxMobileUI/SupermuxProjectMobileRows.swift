import Foundation
import SupermuxMobileCore
import SwiftUI

/// One project row in the phone's Projects section, mirroring the mac
/// sidebar's row (m6-f1): tapping the row toggles the INLINE disclosure
/// (never a navigation push), the trailing info accessory and the long-press
/// menu route to the project DETAIL screen, and the count badges show
/// worktrees/open workspaces. Like the mac row, no run control renders here
/// — run start/stop lives on the detail screen.
///
/// Receives an immutable ``SupermuxProjectRowSnapshot`` plus closures only,
/// per the repo's snapshot-boundary rule.
struct SupermuxProjectMobileRow: View {
    let row: SupermuxProjectRowSnapshot
    let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    let toggleExpanded: @MainActor (_ projectID: String) -> Void
    let openDetail: @MainActor (_ projectID: String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                toggleExpanded(row.id)
            } label: {
                HStack(spacing: 10) {
                    SupermuxProjectMobileAvatar(row: row, size: 32, iconPNGData: iconPNGData)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(row.rootPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    countBadges
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.name)
            .accessibilityHint(row.isExpanded
                ? String(localized: "supermux.projects.section.collapse", defaultValue: "Collapse", bundle: .module)
                : String(localized: "supermux.projects.section.expand", defaultValue: "Expand", bundle: .module))
            .accessibilityIdentifier("SupermuxProjectRow-\(row.id)")
            Button {
                openDetail(row.id)
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(
                localized: "supermux.projects.row.details",
                defaultValue: "Project Details",
                bundle: .module
            ))
            .accessibilityIdentifier("SupermuxProjectDetailButton-\(row.id)")
        }
        .contextMenu {
            // The long-press twin of the info accessory — both route through
            // the same openDetail action (one shared path).
            Button {
                openDetail(row.id)
            } label: {
                Label(
                    String(
                        localized: "supermux.projects.row.details",
                        defaultValue: "Project Details",
                        bundle: .module
                    ),
                    systemImage: "info.circle"
                )
            }
        }
    }

    /// Count badges render only when real data exists (`nil` = hidden, never
    /// a made-up zero badge): the worktree count arrives once a worktrees
    /// fetch has run for the project, the workspace count from the §6 join.
    @ViewBuilder
    private var countBadges: some View {
        if let count = row.worktreeCount {
            countBadge(systemImage: "arrow.triangle.branch", count: count)
        }
        if let count = row.openWorkspaceCount {
            countBadge(systemImage: "square.on.square", count: count)
        }
    }

    private func countBadge(systemImage: String, count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(verbatim: "\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

/// The nested list rows under one EXPANDED project, in the mac sidebar's
/// order: the project's open workspaces (activity dots, tap navigates), then
/// its unopened worktrees (PR badges, tap opens via `worktree.open`). Emits
/// plain sibling rows for the host `Section` — each an immutable snapshot
/// plus closures, per the snapshot-boundary rule.
struct SupermuxProjectNestedRows: View {
    let row: SupermuxProjectRowSnapshot
    let actions: SupermuxProjectsSectionActions

    /// Leading inset that tucks nested rows under the project title.
    private static let indent: CGFloat = 28

    var body: some View {
        ForEach(row.openWorkspaces) { workspace in
            SupermuxProjectWorkspaceRow(workspace: workspace, selectWorkspace: actions.selectWorkspace)
                .padding(.leading, Self.indent)
                .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
                .listRowSeparator(.hidden)
        }
        switch row.nestedWorktrees {
        case .unavailable:
            EmptyView()
        case .loading:
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
            .padding(.leading, Self.indent)
            .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
            .listRowSeparator(.hidden)
        case .loaded(let worktrees):
            if worktrees.isEmpty, row.openWorkspaces.isEmpty {
                // An expanded project with nothing nested still answers the
                // tap (the mac shows nothing here; a phone list reads better
                // with an explicit empty hint than a dead-looking toggle).
                Text(String(
                    localized: "supermux.projects.nested.empty",
                    defaultValue: "No open workspaces or worktrees yet",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, Self.indent)
                .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
                .listRowSeparator(.hidden)
            }
            ForEach(worktrees) { worktree in
                SupermuxNestedWorktreeRow(worktree: worktree) { tapped in
                    actions.openNestedWorktree(row.id, tapped)
                }
                .padding(.leading, Self.indent)
                .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
                .listRowSeparator(.hidden)
            }
        }
    }
}

/// One unopened worktree nested under an expanded project: branch glyph,
/// name, dirty indicator, and the PR badge — the phone twin of the mac
/// sidebar's `SupermuxWorktreeRowView`. Tapping opens a workspace in the
/// worktree (m2-f2 flow) through the passed closure.
struct SupermuxNestedWorktreeRow: View {
    let worktree: SupermuxWorktreeRowSnapshot
    let open: @MainActor (_ worktree: SupermuxWorktreeRowSnapshot) -> Void

    var body: some View {
        Button {
            open(worktree)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(worktree.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if worktree.isDirty {
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
                if let pullRequest = worktree.pullRequest {
                    SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(worktree.displayName)
        .accessibilityHint(String(
            localized: "supermux.worktrees.open",
            defaultValue: "Open Workspace",
            bundle: .module
        ))
        .accessibilityIdentifier("SupermuxNestedWorktreeRow-\(worktree.id)")
    }
}

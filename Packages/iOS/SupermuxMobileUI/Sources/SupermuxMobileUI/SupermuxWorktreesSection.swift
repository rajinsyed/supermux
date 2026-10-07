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
    let isPreparingNewWorktree: Bool
    let newWorktree: @MainActor () -> Void
    let openWorktree: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void
    let requestRemoval: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void

    var body: some View {
        Section {
            if !hasLoaded {
                // Placeholder rows in the loaded row's shape (system redaction
                // shimmer), not a lone mini spinner: the section keeps its
                // geometry and the wait reads as content arriving.
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                        Text(verbatim: "placeholder-branch")
                            .font(.body)
                        Spacer(minLength: 4)
                    }
                    .redacted(reason: .placeholder)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(
                    localized: "supermux.worktrees.loading",
                    defaultValue: "Loading worktrees…",
                    bundle: .module
                ))
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
                    if isPreparingNewWorktree {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isPreparingNewWorktree)
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

/// One worktree row: branch name, dirty indicator, and either a
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

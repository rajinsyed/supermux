import Foundation
import SupermuxMobileCore
import SwiftUI

/// One project row in the phone's Projects section.
///
/// A phone row is not a scaled-down Mac sidebar row: the Mac's 12pt name and
/// bare worktree pill assume a pointer, a hover state, and a dense window. This
/// row follows the app's own rich-row idiom instead (the shape `MacComputerRow`
/// uses): an accent-gradient avatar, a `.headline` name, and a secondary line
/// that actually reports the project's state — open workspaces, worktrees,
/// running — rather than making the user expand the row to find out.
///
/// The whole row is one tap target that toggles the inline disclosure; the
/// trailing chevron rotates rather than swapping glyphs, so expansion reads as
/// one continuous motion. Project details stay reachable through the row's
/// long-press menu and its explicit info accessory.
///
/// Receives an immutable ``SupermuxProjectRowSnapshot`` plus closures only, per
/// the repo's snapshot-boundary rule.
struct SupermuxProjectMobileRow: View {
    let row: SupermuxProjectRowSnapshot
    let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    let toggleExpanded: @MainActor (_ projectID: String) -> Void
    let openDetail: @MainActor (_ projectID: String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: SupermuxProjectRowMetrics.avatarTextGap) {
            SupermuxProjectAvatar(
                row: row,
                size: SupermuxProjectRowMetrics.avatarSize,
                iconPNGData: iconPNGData
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitle
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            SupermuxHaptics.selection()
            withAnimation(reduceMotion ? nil : SupermuxProjectMotion.disclosure) {
                toggleExpanded(row.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(row.isExpanded
            ? String(localized: "supermux.projects.section.collapse", defaultValue: "Collapse", bundle: .module)
            : String(localized: "supermux.projects.section.expand", defaultValue: "Expand", bundle: .module))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("SupermuxProjectRow-\(row.id)")
        .accessibilityAction(named: Text(String(
            localized: "supermux.projects.row.details",
            defaultValue: "Project Details",
            bundle: .module
        ))) {
            openDetail(row.id)
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

    /// The state line: what the row would otherwise force a tap to discover.
    /// Falls back to the project's default branch, then its folder name, so
    /// the line is never empty and never a bare repetition of the title.
    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 6) {
            if row.run?.isRunning == true {
                SupermuxRunActiveDot()
                    .accessibilityHidden(true)
            }
            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let count = row.openWorkspaceCount, count > 0 {
            parts.append(String(
                localized: "supermux.projects.row.workspaceCount",
                defaultValue: "\(count) open",
                bundle: .module
            ))
        }
        if let count = row.worktreeCount, count > 0 {
            parts.append(String(
                localized: "supermux.projects.row.worktreeCount",
                defaultValue: "\(count) worktrees",
                bundle: .module
            ))
        }
        if parts.isEmpty {
            if let branch = row.defaultBranch, !branch.isEmpty {
                return branch
            }
            let folder = (row.rootPath as NSString).lastPathComponent
            return folder.isEmpty ? row.rootPath : folder
        }
        return parts.joined(separator: " · ")
    }

    /// Info accessory plus the disclosure chevron. The chevron ROTATES between
    /// states instead of swapping symbols, so the row animates as one piece.
    private var trailing: some View {
        HStack(spacing: 2) {
            Button {
                openDetail(row.id)
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "supermux.projects.row.details",
                defaultValue: "Project Details",
                bundle: .module
            ))
            .accessibilityIdentifier("SupermuxProjectDetailButton-\(row.id)")
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .animation(reduceMotion ? nil : SupermuxProjectMotion.disclosure, value: row.isExpanded)
                .accessibilityHidden(true)
        }
        // VoiceOver reaches details through the row's custom action; the
        // duplicate button would otherwise be announced twice.
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        subtitleText
    }
}

/// Shared row geometry. The nested rows read the same constants so a nested
/// title lines up under the project title instead of guessing an indent.
/// lint:allow namespace-enum — layout-constant table shared by the project row and its nested rows; stateless, nothing to instantiate.
enum SupermuxProjectRowMetrics {
    /// Avatar edge length, matching the app's rich-row avatars.
    static let avatarSize: CGFloat = 40
    /// Gap between the avatar and the text column.
    static let avatarTextGap: CGFloat = 12
    /// Where a nested row's content starts: exactly the project title's
    /// leading edge.
    static var nestedIndent: CGFloat { avatarSize + avatarTextGap }
}

/// The section's motion vocabulary, matching the app's house curve
/// (`.snappy`), so a disclosure here feels like the rest of the phone app.
/// Every caller pairs these with an `accessibilityReduceMotion` check.
/// lint:allow namespace-enum — animation-constant table shared across the section's views; stateless, nothing to instantiate.
enum SupermuxProjectMotion {
    /// Project expand/collapse.
    static let disclosure = Animation.snappy(duration: 0.26)
    /// Rows appearing or leaving inside a disclosure.
    static let nestedContent = Animation.snappy(duration: 0.22)
}

/// The nested list rows under one project: the project's open workspaces are
/// ALWAYS visible, while its unopened worktrees sit behind the disclosure.
///
/// Nested rows are drawn against a hairline guide tinted with the project's
/// accent, so a long list stays legible about which rows belong to which
/// project — the flat 28pt indent it replaces gave no such signal.
///
/// Emits plain sibling rows for the host `Section` — each an immutable
/// snapshot plus closures, per the snapshot-boundary rule.
struct SupermuxProjectNestedRows: View {
    let row: SupermuxProjectRowSnapshot
    let actions: SupermuxProjectsSectionActions

    var body: some View {
        ForEach(row.openWorkspaces) { workspace in
            nested {
                SupermuxProjectWorkspaceRow(
                    workspace: workspace,
                    selectWorkspace: actions.selectWorkspace
                )
            }
        }
        // `.unavailable` while collapsed (the model gates on isExpanded), so
        // the worktree slice renders only under an expanded project.
        switch row.nestedWorktrees {
        case .unavailable:
            EmptyView()
        case .loading:
            nested {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(
                        localized: "supermux.worktrees.loading",
                        defaultValue: "Loading worktrees…",
                        bundle: .module
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        case .loaded(let worktrees):
            if worktrees.isEmpty, row.openWorkspaces.isEmpty {
                nested {
                    Text(String(
                        localized: "supermux.projects.nested.empty",
                        defaultValue: "No open workspaces or worktrees yet",
                        bundle: .module
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(worktrees) { worktree in
                nested {
                    SupermuxNestedWorktreeRow(worktree: worktree) { tapped in
                        actions.openNestedWorktree(row.id, tapped)
                    }
                }
            }
        }
    }

    /// Wraps one nested row in the accent guide + indent shared by all of them.
    private func nested(@ViewBuilder _ content: @escaping () -> some View) -> some View {
        SupermuxNestedRowContainer(accent: row.accent, content: content)
            .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
            .listRowSeparator(.hidden)
    }
}

/// The indent + accent guide every nested row sits behind.
///
/// Container-agnostic on purpose: the same treatment is used by the SwiftUI
/// `List` path (macOS) and by the UIKit-table path (iOS), which cannot use
/// `listRowInsets`/`listRowSeparator` at all. Those list-only modifiers are
/// applied by the `List` caller, never in here.
struct SupermuxNestedRowContainer<Content: View>: View {
    let accent: SupermuxProjectAccent
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accent.color.opacity(0.35))
                .frame(width: 2)
                .clipShape(Capsule())
                .padding(.leading, SupermuxProjectRowMetrics.nestedIndent / 2 - 1)
                .padding(.trailing, SupermuxProjectRowMetrics.nestedIndent / 2 - 1)
                .accessibilityHidden(true)
            content()
        }
        .transition(.opacity)
    }
}

/// One unopened worktree nested under an expanded project: branch glyph, name,
/// dirty indicator, and the PR badge — the phone twin of the mac sidebar's
/// `SupermuxWorktreeRowView`. Tapping opens a workspace in the worktree (m2-f2
/// flow) through the passed closure.
struct SupermuxNestedWorktreeRow: View {
    let worktree: SupermuxWorktreeRowSnapshot
    let open: @MainActor (_ worktree: SupermuxWorktreeRowSnapshot) -> Void

    var body: some View {
        Button {
            SupermuxHaptics.selection()
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
            .padding(.vertical, 4)
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

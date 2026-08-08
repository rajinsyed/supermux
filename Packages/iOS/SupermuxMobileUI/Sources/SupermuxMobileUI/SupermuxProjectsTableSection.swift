public import SwiftUI

/// The Projects section as a SINGLE self-contained subtree, for hosting inside
/// one row of the iOS workspace `UITableView`.
///
/// The iPhone's workspace list is not a SwiftUI `List` — it is a UIKit table
/// (`WorkspaceListTable`) whose rows are `UIHostingConfiguration` cells. The
/// `List`-shaped ``SupermuxProjectsMobileSection`` cannot render there at all:
/// `Section`, `listRowInsets`, and `listRowSeparator` are inert outside a
/// `List`, so the section needs a container-agnostic twin that owns its own
/// padding. This is that twin — same rows, same actions, laid out in a stack.
///
/// It is deliberately ONE row rather than one row per project: the table's
/// exact-height machinery then measures the whole section as a unit, project
/// disclosure stays a payload change instead of a structural reload, and the
/// UIKit↔model index mapping used by workspace drag-reorder never has to learn
/// about non-workspace rows.
public struct SupermuxProjectsTableSection: View {
    private let section: SupermuxProjectsSectionSnapshot
    private let actions: SupermuxProjectsSectionActions

    /// Creates the hosted section.
    /// - Parameters:
    ///   - section: The section's value snapshot (from the model).
    ///   - actions: The closure bundle rows act through.
    public init(
        section: SupermuxProjectsSectionSnapshot,
        actions: SupermuxProjectsSectionActions
    ) {
        self.section = section
        self.actions = actions
    }

    /// Horizontal inset matching the table's own workspace-row margins, so the
    /// section's avatars line up with the workspace rows beneath it.
    private static let horizontalInset: CGFloat = 12

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SupermuxProjectsSectionHeader(
                isCollapsed: section.isCollapsed,
                toggleCollapsed: actions.toggleCollapsed,
                editing: actions.editing
            )
            .padding(.vertical, 6)
            if !section.isCollapsed {
                content
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("SupermuxProjectsTableSection")
    }

    @ViewBuilder
    private var content: some View {
        if !section.hasLoaded {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    SupermuxProjectSkeletonRow(index: index)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(
                localized: "supermux.projects.loading",
                defaultValue: "Loading projects…",
                bundle: .module
            ))
        } else if section.rows.isEmpty {
            SupermuxProjectsEmptyState(editing: actions.editing)
        } else {
            VStack(spacing: 0) {
                ForEach(section.rows) { row in
                    SupermuxProjectMobileRow(
                        row: row,
                        iconPNGData: actions.iconPNGData,
                        toggleExpanded: actions.toggleProjectExpanded,
                        openDetail: actions.openProjectDetail
                    )
                    SupermuxProjectTableNestedRows(row: row, actions: actions)
                }
            }
        }
    }
}

/// The nested rows under one project, laid out for the stack-hosted section.
///
/// Mirrors ``SupermuxProjectNestedRows`` exactly, minus the `List`-only row
/// modifiers: open workspaces are always visible, unopened worktrees appear
/// behind the project's disclosure, and every nested row sits behind the
/// project's accent guide.
struct SupermuxProjectTableNestedRows: View {
    let row: SupermuxProjectRowSnapshot
    let actions: SupermuxProjectsSectionActions

    var body: some View {
        ForEach(row.openWorkspaces) { workspace in
            SupermuxNestedRowContainer(accent: row.accent) {
                SupermuxProjectWorkspaceRow(
                    workspace: workspace,
                    selectWorkspace: actions.selectWorkspace
                )
            }
        }
        switch row.nestedWorktrees {
        case .unavailable:
            EmptyView()
        case .loading:
            SupermuxNestedRowContainer(accent: row.accent) {
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
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        case .loaded(let worktrees):
            if worktrees.isEmpty, row.openWorkspaces.isEmpty {
                SupermuxNestedRowContainer(accent: row.accent) {
                    Text(String(
                        localized: "supermux.projects.nested.empty",
                        defaultValue: "No open workspaces or worktrees yet",
                        bundle: .module
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }
            }
            ForEach(worktrees) { worktree in
                SupermuxNestedRowContainer(accent: row.accent) {
                    SupermuxNestedWorktreeRow(worktree: worktree) { tapped in
                        actions.openNestedWorktree(row.id, tapped)
                    }
                }
            }
        }
    }
}

/// What the hosting table row must re-measure on.
///
/// The section's snapshot changes far more often than its HEIGHT does: agent
/// activity, PR state, run state, and unread flags all repaint rows that are
/// exactly the same size. Re-measuring a subtree this tall on every one of
/// those would put the whole section through `systemLayoutSizeFitting` during
/// live agent output — the precise cost the exact-height table exists to
/// avoid. So the host keys its height cache on THIS value, which changes only
/// when something structural does: visibility, collapse, load state, the set
/// and order of projects, and each project's expansion + nested row counts.
///
/// Pure value logic, unit-testable without a table.
public struct SupermuxProjectsTableLayoutIdentity: Equatable, Sendable {
    /// The identity as an opaque, stable string — what the host folds into its
    /// own row-height cache key. Equal fingerprints mean equal measured height.
    public let fingerprint: String

    /// Derives the layout identity of a section snapshot.
    /// - Parameters:
    ///   - section: The section's current value snapshot.
    ///   - canEdit: Whether the editing seam is live. It gates the header's
    ///     "+" and the empty state's Add Project button, both of which change
    ///     the measured height, and it is carried on the ACTIONS bundle rather
    ///     than the snapshot — so the host must pass it in.
    public init(section: SupermuxProjectsSectionSnapshot, canEdit: Bool) {
        let edit = canEdit ? "e" : "-"
        guard section.isVisible else {
            self.fingerprint = "hidden"
            return
        }
        guard !section.isCollapsed else {
            self.fingerprint = "collapsed:\(edit)"
            return
        }
        guard section.hasLoaded else {
            self.fingerprint = "loading:\(edit)"
            return
        }
        if section.rows.isEmpty {
            self.fingerprint = "empty:\(edit)"
            return
        }
        // Name length matters: a long name wraps the row's title and changes
        // the measured height, while the name's spelling does not.
        let rows = section.rows.map { row in
            let nested: String
            switch row.nestedWorktrees {
            case .unavailable: nested = "u"
            case .loading: nested = "l"
            case .loaded(let worktrees): nested = "n\(worktrees.count)"
            }
            let subtitleShape = [
                row.openWorkspaceCount.map(String.init) ?? "-",
                row.worktreeCount.map(String.init) ?? "-",
                row.run?.isRunning == true ? "r" : "-",
            ].joined(separator: ",")
            return [
                row.id,
                String(row.name.count),
                row.isExpanded ? "e" : "c",
                String(row.openWorkspaces.count),
                nested,
                subtitleShape,
            ].joined(separator: ":")
        }
        self.fingerprint = "rows:\(section.editingFingerprint)|" + rows.joined(separator: ";")
    }
}

extension SupermuxProjectsSectionSnapshot {
    /// Whether the editing seam is live — it decides whether the header's "+"
    /// and the empty state's button render, both of which affect height.
    fileprivate var editingFingerprint: String {
        showsPresets ? "p" : "-"
    }
}

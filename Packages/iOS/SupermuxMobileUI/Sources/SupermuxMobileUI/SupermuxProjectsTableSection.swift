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
///
/// Being one cell is also why swipe actions here are the fork's own
/// (``SupermuxSidebarSwipeRow``) rather than `.swipeActions`: the table gives
/// its native swipe to the CELL, and this cell is the entire section.
public struct SupermuxProjectsTableSection: View {
    private let section: SupermuxProjectsSectionSnapshot
    private let actions: SupermuxProjectsSectionActions

    /// The one row currently showing its swipe actions, across every project
    /// and nested row. Owned here — the section is the smallest view that
    /// outlives an individual row's recycling, and one-open-at-a-time is the
    /// behavior every native list has.
    @State private var openSwipeRowID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    public var body: some View {
        VStack(alignment: .leading, spacing: SupermuxProjectRowMetrics.rowSpacing) {
            SupermuxProjectsSectionHeader(
                isCollapsed: section.isCollapsed,
                projectCount: section.hasLoaded ? section.rows.count : nil,
                toggleCollapsed: actions.toggleCollapsed,
                editing: actions.editing
            )
            if !section.isCollapsed {
                content
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A collapse changes the section's height, so it must animate with the
        // hosting table row's own re-measure rather than snapping ahead of it.
        .animation(reduceMotion ? nil : SupermuxProjectMotion.disclosure, value: section.isCollapsed)
        // Any structural change closes an open tray, matching every native
        // list. Keyed on the SWIPEABLE rows' identity, not just the project
        // ids: collapsing the section or a project would otherwise hide a row
        // with its tray still open, so it would come back open — and because
        // a worktree row is identified by its PATH, a worktree removed and
        // recreated at the same path would inherit the previous one's open
        // state along with its actions.
        .onChange(of: swipeableRowIdentity) { _, _ in
            openSwipeRowID = nil
        }
        .accessibilityIdentifier("SupermuxProjectsTableSection")
    }

    /// Every currently-swipeable row, in order — what an open tray's validity
    /// depends on. A collapsed section contributes nothing, so folding it
    /// changes this value and closes the tray.
    ///
    /// Covers all three row types, not just worktrees: every one of them
    /// swipes now, and a row whose identity can be REUSED (a worktree is keyed
    /// by path; a workspace at the same id can be closed and reopened) would
    /// otherwise inherit the previous occupant's open tray along with its
    /// actions.
    private var swipeableRowIdentity: [String] {
        guard !section.isCollapsed else { return [] }
        return section.rows.flatMap { row -> [String] in
            var identities = ["p:\(row.id)"]
            identities.append(contentsOf: row.openWorkspaces.map { "w:\($0.id)" })
            if case .loaded(let worktrees) = row.nestedWorktrees {
                identities.append(contentsOf: worktrees.map { "t:\(row.id):\($0.id)" })
            }
            return identities
        }
    }

    /// Outer inset. The rows carry their own
    /// ``SupermuxProjectRowMetrics/rowHorizontalPadding`` inside their press
    /// plates, so this is deliberately smaller than the table's 12pt workspace
    /// margin: 4 + 10 lands the avatars two points inside it, which is what
    /// makes the plates read as inset cards rather than full-bleed bands.
    private static let horizontalInset: CGFloat = 4

    @ViewBuilder
    private var content: some View {
        if !section.hasLoaded {
            VStack(spacing: SupermuxProjectRowMetrics.rowSpacing) {
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
            VStack(spacing: SupermuxProjectRowMetrics.rowSpacing) {
                ForEach(section.rows) { row in
                    SupermuxSidebarSwipeRow(
                        rowID: "project:\(row.id)",
                        openRowID: $openSwipeRowID,
                        actions: projectSwipeActions(for: row)
                    ) {
                        SupermuxProjectMobileRow(
                            row: row,
                            iconPNGData: actions.iconPNGData,
                            toggleExpanded: actions.toggleProjectExpanded,
                            openWorkspace: actions.openProjectWorkspace,
                            openDetail: actions.openProjectDetail,
                            newWorktree: section.showsWorktreeCreation
                                ? actions.requestNewWorktree
                                : nil
                        )
                    }
                    SupermuxProjectTableNestedRows(
                        row: row,
                        actions: actions,
                        showsNewWorktree: section.showsWorktreeCreation,
                        openSwipeRowID: $openSwipeRowID
                    )
                }
            }
        }
    }

    /// A project row's swipe tray: New Worktree first (the fork's most-used
    /// creation flow), then Project Details. Worktree creation swipes only on
    /// a `supermux.worktrees.v1` host.
    private func projectSwipeActions(for row: SupermuxProjectRowSnapshot) -> [SupermuxSwipeAction] {
        var trayActions: [SupermuxSwipeAction] = []
        if section.showsWorktreeCreation {
            trayActions.append(SupermuxSwipeAction(
                id: "new-worktree",
                systemImage: "arrow.triangle.branch",
                title: String(
                    localized: "supermux.worktrees.new",
                    defaultValue: "New Worktree",
                    bundle: .module
                ),
                tint: .accentColor,
                perform: { actions.requestNewWorktree(row.id) }
            ))
        }
        trayActions.append(SupermuxSwipeAction(
            id: "details",
            systemImage: "info.circle",
            title: String(
                localized: "supermux.projects.row.details",
                defaultValue: "Project Details",
                bundle: .module
            ),
            tint: .gray,
            perform: { actions.openProjectDetail(row.id) }
        ))
        return trayActions
    }

}

/// The nested rows under one project, laid out for the stack-hosted section.
///
/// Mirrors ``SupermuxProjectNestedRows`` exactly, minus the `List`-only row
/// modifiers: open workspaces are always visible, unopened worktrees appear
/// behind the project's disclosure, and every nested row aligns under the
/// project title.
struct SupermuxProjectTableNestedRows: View {
    let row: SupermuxProjectRowSnapshot
    let actions: SupermuxProjectsSectionActions
    /// Whether the disclosure ends in the inline New Worktree row.
    var showsNewWorktree = false
    @Binding var openSwipeRowID: String?

    var body: some View {
        ForEach(row.openWorkspaces) { workspace in
            SupermuxSidebarSwipeRow(
                rowID: "workspace:\(workspace.id)",
                openRowID: $openSwipeRowID,
                actions: closeAction(for: workspace)
            ) {
                SupermuxNestedRowContainer {
                    SupermuxSidebarWorkspaceRow(
                        workspace: workspace,
                        selectWorkspace: actions.selectWorkspace,
                        closeWorkspace: actions.closeWorkspace
                    )
                }
            }
        }
        switch row.nestedWorktrees {
        case .unavailable:
            EmptyView()
        case .loading:
            SupermuxNestedRowContainer {
                SupermuxNestedSkeletonRow()
            }
            .transition(SupermuxProjectMotion.nestedTransition)
        case .loaded(let worktrees):
            if worktrees.isEmpty, row.openWorkspaces.isEmpty, !showsNewWorktree {
                SupermuxNestedRowContainer {
                    SupermuxNestedNoticeRow(text: String(
                        localized: "supermux.projects.nested.empty",
                        defaultValue: "No open workspaces or worktrees yet",
                        bundle: .module
                    ))
                }
                .transition(SupermuxProjectMotion.nestedTransition)
            }
            ForEach(worktrees) { worktree in
                // Swipe-to-remove, the same gesture the project detail
                // screen's worktree rows have had since m2 — and routed
                // through the same store, so the two can never disagree.
                SupermuxSidebarSwipeRow(
                    rowID: "worktree:\(worktree.id)",
                    openRowID: $openSwipeRowID,
                    actions: [
                        SupermuxSwipeAction(
                            id: "remove",
                            systemImage: "trash",
                            title: String(
                                localized: "supermux.worktrees.remove.title",
                                defaultValue: "Remove Worktree",
                                bundle: .module
                            ),
                            tint: .red,
                            isDestructive: true,
                            perform: { actions.requestNestedWorktreeRemoval(row.id, worktree) }
                        ),
                    ]
                ) {
                    SupermuxNestedRowContainer(symbol: "arrow.triangle.branch") {
                        SupermuxNestedWorktreeRow(
                            worktree: worktree,
                            open: { tapped in actions.openNestedWorktree(row.id, tapped) },
                            requestRemoval: { tapped in
                                actions.requestNestedWorktreeRemoval(row.id, tapped)
                            }
                        )
                    }
                }
                .transition(SupermuxProjectMotion.nestedTransition)
            }
            if showsNewWorktree {
                SupermuxNestedRowContainer(symbol: "plus") {
                    SupermuxNestedNewWorktreeRow(
                        projectID: row.id,
                        isPreparing: actions.preparingNewWorktreeProjectID == row.id,
                        newWorktree: actions.requestNewWorktree
                    )
                }
                .transition(SupermuxProjectMotion.nestedTransition)
            }
        }
    }

    /// The nested workspace row's swipe tray: the shell's own close action, or
    /// nothing when the connected Mac can't close workspaces. An empty tray
    /// makes ``SupermuxSidebarSwipeRow`` inert, so the row simply doesn't
    /// swipe rather than revealing a dead button.
    private func closeAction(
        for workspace: SupermuxProjectWorkspaceRowSnapshot
    ) -> [SupermuxSwipeAction] {
        guard let closeWorkspace = actions.closeWorkspace else { return [] }
        return [
            SupermuxSwipeAction(
                id: "close",
                systemImage: "xmark",
                title: String(
                    localized: "supermux.workspaces.row.close",
                    defaultValue: "Close Workspace",
                    bundle: .module
                ),
                tint: .red,
                isDestructive: true,
                perform: { closeWorkspace(workspace.id) }
            ),
        ]
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
        // Worktree creation adds the inline New Worktree row to every
        // EXPANDED project's disclosure (and suppresses the empty notice), so
        // its availability is part of the measured shape.
        let creation = section.showsWorktreeCreation ? "n" : "-"
        // Name length matters: a long name wraps the row's title and changes
        // the measured height, while the name's spelling does not.
        let rows = section.rows.map { row in
            let nested: String
            switch row.nestedWorktrees {
            case .unavailable: nested = "u"
            case .loading: nested = "l"
            case .loaded(let worktrees): nested = "n\(worktrees.count)"
            }
            // Only the branch-count pill's PRESENCE changes the row's height —
            // the count's digits do not — but a nested workspace row grows by
            // its branch subtitle, so that has to be part of the shape.
            let shape = [
                row.worktreeCount.map { $0 > 0 ? "w" : "-" } ?? "-",
                row.openWorkspaces.map { $0.branch == nil ? "1" : "2" }.joined(),
            ].joined(separator: ",")
            return [
                row.id,
                String(row.name.count),
                row.isExpanded ? "e" : "c",
                String(row.openWorkspaces.count),
                nested,
                shape,
            ].joined(separator: ":")
        }
        self.fingerprint = "rows:\(section.editingFingerprint):\(creation)|" + rows.joined(separator: ";")
    }
}

extension SupermuxProjectsSectionSnapshot {
    /// Whether the editing seam is live — it decides whether the header's "+"
    /// and the empty state's button render, both of which affect height.
    fileprivate var editingFingerprint: String {
        showsPresets ? "p" : "-"
    }
}

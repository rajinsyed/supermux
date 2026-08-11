import Foundation
import SupermuxMobileCore
import SwiftUI

/// One project row in the phone's Projects sidebar.
///
/// Deliberately the Mac sidebar row, not a phone "rich row": a small avatar, a
/// single name, and — only when the project actually has unopened worktrees —
/// the Mac's branch-count pill, which doubles as the disclosure. Everything the
/// old row shouted (a derived "1 open · 2 worktrees" subtitle, an `info.circle`
/// accessory, a trailing chevron) is either already visible as nested rows
/// underneath or reachable by tapping, so none of it earned a permanent slot.
///
/// Tapping the row opens a workspace at the project ROOT, exactly like
/// clicking the row in the Mac sidebar (`SupermuxProjectRowActions.openLocal`).
/// It used to push the project's detail screen instead, which meant the phone's
/// primary gesture landed somewhere the Mac's never goes; detail now lives in
/// the long-press menu, where the Mac keeps its own per-project actions. The
/// pill still owns expand/collapse, so the two never fight over one target.
///
/// Receives an immutable ``SupermuxProjectRowSnapshot`` plus closures only, per
/// the repo's snapshot-boundary rule.
struct SupermuxProjectMobileRow: View {
    let row: SupermuxProjectRowSnapshot
    let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    let toggleExpanded: @MainActor (_ projectID: String) -> Void
    let openWorkspace: @MainActor (_ projectID: String) -> Void
    let openDetail: @MainActor (_ projectID: String) -> Void
    /// Opens the New Worktree sheet (m7 sidebar create flow); `nil` hides the
    /// menu entry (no session, or no `supermux.worktrees.v1`).
    var newWorktree: (@MainActor (_ projectID: String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Not `private`: a private stored property suppresses the memberwise
    // initializer this row is constructed with.
    var metrics = SupermuxScaledRowMetrics()

    /// The Mac's capsule counts worktrees WITHOUT an open workspace, and is
    /// absent when there are none — a project with nothing to disclose shows
    /// no disclosure at all.
    private var unopenedWorktreeCount: Int? {
        guard let count = row.worktreeCount, count > 0 else { return nil }
        return count
    }

    var body: some View {
        Button {
            SupermuxHaptics.selection()
            openWorkspace(row.id)
        } label: {
            HStack(spacing: metrics.avatarTextGap) {
                SupermuxProjectAvatar(
                    row: row,
                    size: metrics.avatarSize,
                    iconPNGData: iconPNGData
                )
                Text(row.name)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, SupermuxProjectRowMetrics.rowHorizontalPadding)
            .frame(minHeight: metrics.minimumRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SupermuxSidebarRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(String(
            localized: "supermux.projects.row.openHint",
            defaultValue: "Opens a workspace at the project root",
            bundle: .module
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("SupermuxProjectRow-\(row.id)")
        .accessibilityAction(named: Text(disclosureActionTitle)) {
            toggleExpanded(row.id)
        }
        .accessibilityAction(named: Text(String(
            localized: "supermux.projects.row.details",
            defaultValue: "Project Details",
            bundle: .module
        ))) {
            openDetail(row.id)
        }
        .accessibilityActions {
            if let newWorktree {
                Button(String(
                    localized: "supermux.worktrees.new",
                    defaultValue: "New Worktree",
                    bundle: .module
                )) {
                    newWorktree(row.id)
                }
            }
        }
        .supermuxSidebarContextMenu { contextMenu }
    }

    /// Trailing status: the Mac's worktree pill, and nothing else.
    ///
    /// A green "running" dot used to lead this cluster. The Mac project row
    /// carries no run affordance at all — a run is surfaced on the nested
    /// WORKSPACE row that hosts it (`SupermuxRunIndicator`), which is where it
    /// is actually actionable — so the project-level dot was a phone-only
    /// duplicate of state already shown one row below.
    @ViewBuilder
    private var trailing: some View {
        if let count = unopenedWorktreeCount {
            worktreePill(count)
        }
    }

    /// The Mac's `⑂ N ›` capsule, and the row's only disclosure control.
    ///
    /// Its visual footprint stays capsule-small while its hit region is padded
    /// out to the full row height — a 20pt-tall pill is the right density here
    /// and the wrong tap target, so the two are sized separately.
    private func worktreePill(_ count: Int) -> some View {
        Button {
            SupermuxHaptics.selection()
            toggleExpanded(row.id)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(.caption2, weight: .semibold))
                Text(count.formatted())
                    .font(.system(.caption2, weight: .semibold).monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.system(.caption2, weight: .bold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
            // Invisible hit padding: the capsule stays 20pt tall, the target
            // fills the row.
            .padding(.vertical, 10)
            .padding(.leading, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : SupermuxProjectMotion.disclosure, value: row.isExpanded)
        .accessibilityLabel(disclosureActionTitle)
        .accessibilityValue(worktreeCountText(count))
        .accessibilityIdentifier("SupermuxProjectWorktreeDisclosure-\(row.id)")
    }

    /// The long-press menu, in the Mac's order: the primary open action first
    /// (so the menu restates what a tap does), then the disclosure, then the
    /// detail screen the row tap used to occupy.
    @ViewBuilder
    private var contextMenu: some View {
        Button {
            openWorkspace(row.id)
        } label: {
            Label {
                Text(String(
                    localized: "supermux.projects.row.openLocal",
                    defaultValue: "Open Local Workspace",
                    bundle: .module
                ))
            } icon: {
                Image(systemName: "macwindow")
            }
        }
        if let newWorktree {
            Button {
                newWorktree(row.id)
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.worktrees.new",
                        defaultValue: "New Worktree",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
            }
        }
        if unopenedWorktreeCount != nil {
            Button {
                toggleExpanded(row.id)
            } label: {
                Label {
                    Text(disclosureActionTitle)
                } icon: {
                    Image(systemName: row.isExpanded ? "chevron.up" : "chevron.down")
                }
            }
        }
        Divider()
        Button {
            openDetail(row.id)
        } label: {
            Label {
                Text(String(
                    localized: "supermux.projects.row.details",
                    defaultValue: "Project Details",
                    bundle: .module
                ))
            } icon: {
                Image(systemName: "info.circle")
            }
        }
    }

    private var disclosureActionTitle: String {
        row.isExpanded
            ? String(
                localized: "supermux.projects.row.collapseWorktrees",
                defaultValue: "Hide Worktrees",
                bundle: .module
            )
            : String(
                localized: "supermux.projects.row.expandWorktrees",
                defaultValue: "Show Worktrees",
                bundle: .module
            )
    }

    /// What VoiceOver reads after the name: the state the redesigned row no
    /// longer spends a whole subtitle line on.
    private var accessibilityValue: String {
        var parts: [String] = []
        if let count = row.openWorkspaceCount, count > 0 {
            parts.append(workspaceCountText(count))
        }
        if let count = unopenedWorktreeCount {
            parts.append(worktreeCountText(count))
        }
        if row.run?.isRunning == true {
            parts.append(String(
                localized: "supermux.run.running",
                defaultValue: "Running",
                bundle: .module
            ))
        }
        return parts.joined(separator: ", ")
    }

    private func workspaceCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "supermux.projects.row.workspaceCount",
                defaultValue: "%lld open",
                bundle: .module
            ),
            Int64(count)
        )
    }

    private func worktreeCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "supermux.projects.row.worktreeCount",
                defaultValue: "%lld worktrees",
                bundle: .module
            ),
            Int64(count)
        )
    }
}

/// Aligns one nested row's content under its project's TITLE.
///
/// Mirrors the Mac sidebar, where a nested row reuses the project row's avatar
/// column — empty for a workspace, a branch glyph for a worktree — so every
/// title in the section shares one leading edge. That alignment is the entire
/// nesting signal; the accent-tinted vertical guide this replaces was pure
/// decoration, and a column of them was most of why the section read cheap.
///
/// Container-agnostic on purpose: the same treatment serves the SwiftUI `List`
/// path (macOS) and the UIKit-table path (iOS), which cannot use
/// `listRowInsets`/`listRowSeparator` at all. Those list-only modifiers are
/// applied by the `List` caller, never in here.
struct SupermuxNestedRowContainer<Content: View>: View {
    /// SF Symbol drawn in the avatar column, or `nil` to leave it empty.
    var symbol: String?
    @ViewBuilder let content: () -> Content

    private var metrics = SupermuxScaledRowMetrics()

    /// Creates the container.
    /// - Parameters:
    ///   - symbol: SF Symbol for the icon column, or `nil` to leave it empty.
    ///   - content: The row's content, aligned under the project title.
    init(symbol: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.symbol = symbol
        self.content = content
    }

    var body: some View {
        HStack(spacing: metrics.avatarTextGap) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: metrics.avatarSize)
            .accessibilityHidden(true)
            content()
        }
        .padding(.leading, SupermuxProjectRowMetrics.rowHorizontalPadding)
    }
}

/// One open workspace nested under its project, laid out like the Mac
/// sidebar's `SupermuxOpenWorkspaceRowView`: the workspace name over its
/// monospaced branch, with the status cluster — PR badge, run indicator, agent
/// activity, unread — pinned to the trailing edge in the Mac's order.
///
/// Sidebar-specific on purpose: the project DETAIL screen's
/// ``SupermuxProjectWorkspaceRow`` is a `List` row with a navigation chevron
/// and detail-screen type sizes, which is the wrong density here.
struct SupermuxSidebarWorkspaceRow: View {
    let workspace: SupermuxProjectWorkspaceRowSnapshot
    let selectWorkspace: @MainActor (_ workspaceID: String) -> Void
    /// Closes the workspace through the shell's own close path (which owns the
    /// confirmation); `nil` hides the affordance entirely.
    var closeWorkspace: (@MainActor (_ workspaceID: String) -> Void)?

    // Not `private`: see the note on SupermuxProjectMobileRow.metrics.
    var metrics = SupermuxScaledRowMetrics()

    var body: some View {
        Button {
            SupermuxHaptics.selection()
            selectWorkspace(workspace.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let branch = workspace.branch {
                        Text(branch)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                statusCluster
            }
            .padding(.trailing, SupermuxProjectRowMetrics.rowHorizontalPadding)
            .frame(minHeight: metrics.minimumRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SupermuxSidebarRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workspace.name)
        .accessibilityValue(workspace.activity.map(SupermuxWorkspaceActivityDot.label(for:)) ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("SupermuxProjectWorkspaceRow-\(workspace.id)")
        .accessibilityActions {
            if let closeWorkspace {
                Button(closeTitle) { closeWorkspace(workspace.id) }
            }
        }
        .supermuxSidebarContextMenu { contextMenu }
    }

    /// Mirrors the Mac's nested-workspace menu: focus, then close.
    @ViewBuilder
    private var contextMenu: some View {
        Button {
            selectWorkspace(workspace.id)
        } label: {
            Label {
                Text(String(
                    localized: "supermux.workspaces.row.focus",
                    defaultValue: "Focus Workspace",
                    bundle: .module
                ))
            } icon: {
                Image(systemName: "arrow.right.circle")
            }
        }
        if let closeWorkspace {
            Divider()
            Button(role: .destructive) {
                closeWorkspace(workspace.id)
            } label: {
                Label {
                    Text(closeTitle)
                } icon: {
                    Image(systemName: "xmark.circle")
                }
            }
        }
    }

    private var closeTitle: String {
        String(
            localized: "supermux.workspaces.row.close",
            defaultValue: "Close Workspace",
            bundle: .module
        )
    }

    /// Mac order exactly — PR badge, run, agent activity, unread.
    ///
    /// The unread badge is back, but as the shared numbered capsule rather than
    /// the bare blue dot removed earlier. That dot went because it was a third
    /// permanently-lit color in a row that already had two, saying nothing the
    /// Mac's own badge didn't say better. The capsule earns its place: it
    /// carries a count, and it is the same badge the workspace list and the Mac
    /// sidebar draw, so one workspace looks the same everywhere it appears.
    @ViewBuilder
    private var statusCluster: some View {
        HStack(spacing: 6) {
            if let pullRequest = workspace.pullRequest {
                SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
            }
            if workspace.isRunning {
                SupermuxMobileRunIndicator()
            }
            SupermuxWorkspaceActivityDot(activity: workspace.activity, size: 7)
            if workspace.hasUnread {
                SupermuxMobileUnreadBadge(count: workspace.unreadCount, fontSize: 9)
            }
        }
    }
}

/// One unopened worktree nested under an expanded project: the branch glyph in
/// the avatar column, the branch name, a dirty marker, and the PR badge — the
/// phone twin of the Mac sidebar's `SupermuxWorktreeRowView`. Tapping opens a
/// workspace in the worktree (m2-f2 flow) through the passed closure.
///
/// Emits only the row's CONTENT; ``SupermuxNestedRowContainer`` supplies the
/// glyph column and the alignment.
struct SupermuxNestedWorktreeRow: View {
    let worktree: SupermuxWorktreeRowSnapshot
    let open: @MainActor (_ worktree: SupermuxWorktreeRowSnapshot) -> Void
    /// Asks to remove the worktree (raises the confirmation — never deletes
    /// directly). The long-press twin of the row's swipe action, routed
    /// through the same request so the two can never disagree.
    var requestRemoval: (@MainActor (_ worktree: SupermuxWorktreeRowSnapshot) -> Void)?

    // Not `private`: see the note on SupermuxProjectMobileRow.metrics.
    var metrics = SupermuxScaledRowMetrics()

    var body: some View {
        Button {
            SupermuxHaptics.selection()
            open(worktree)
        } label: {
            HStack(spacing: 6) {
                Text(worktree.displayName)
                    .font(.system(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if worktree.isDirty {
                    // The dirty marker stays: unlike the status dots this
                    // replaces, it is not duplicated anywhere else on the phone,
                    // and it is what warns that removing this worktree will
                    // need a force. Drawn as a glyph rather than a colored dot
                    // so it reads as information, not as a status light.
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(.caption2))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 6)
                if let pullRequest = worktree.pullRequest {
                    SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
                }
            }
            .padding(.trailing, SupermuxProjectRowMetrics.rowHorizontalPadding)
            .frame(minHeight: metrics.compactRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SupermuxSidebarRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(worktree.displayName)
        .accessibilityValue(worktree.isDirty
            ? String(
                localized: "supermux.worktrees.row.dirty",
                defaultValue: "Uncommitted changes",
                bundle: .module
            )
            : "")
        .accessibilityHint(String(
            localized: "supermux.worktrees.open",
            defaultValue: "Open Workspace",
            bundle: .module
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("SupermuxNestedWorktreeRow-\(worktree.id)")
        .accessibilityActions {
            if let requestRemoval {
                Button(Self.removeTitle) { requestRemoval(worktree) }
            }
        }
        .supermuxSidebarContextMenu { contextMenu }
    }

    /// Mirrors the Mac's worktree menu: open, then the destructive removal.
    @ViewBuilder
    private var contextMenu: some View {
        Button {
            open(worktree)
        } label: {
            Label {
                Text(String(
                    localized: "supermux.worktrees.open",
                    defaultValue: "Open Workspace",
                    bundle: .module
                ))
            } icon: {
                Image(systemName: "arrow.right.circle")
            }
        }
        if let requestRemoval {
            Divider()
            Button(role: .destructive) {
                requestRemoval(worktree)
            } label: {
                Label {
                    Text(Self.removeTitle)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    static var removeTitle: String {
        String(
            localized: "supermux.worktrees.remove.title",
            defaultValue: "Remove Worktree",
            bundle: .module
        )
    }
}

/// The inline "New Worktree" row that closes an expanded project's worktree
/// slice (m7): one tap from the sidebar into the same create sheet the detail
/// screen presents, instead of the old four-step trip through Project Details.
///
/// Styled as a quiet tertiary action — a plus glyph in the branch column and
/// a secondary label — so it reads as an affordance of the disclosure, not as
/// another worktree. Shows a spinner while the branch snapshot it needs is
/// being fetched.
struct SupermuxNestedNewWorktreeRow: View {
    let projectID: String
    /// Whether THIS project's sheet is being prepared (branch fetch in
    /// flight) — the row's label yields to a spinner.
    let isPreparing: Bool
    let newWorktree: @MainActor (_ projectID: String) -> Void

    // Not `private`: see the note on SupermuxProjectMobileRow.metrics.
    var metrics = SupermuxScaledRowMetrics()

    var body: some View {
        Button {
            SupermuxHaptics.selection()
            newWorktree(projectID)
        } label: {
            HStack(spacing: 7) {
                if isPreparing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(String(
                    localized: "supermux.worktrees.new",
                    defaultValue: "New Worktree",
                    bundle: .module
                ))
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.trailing, SupermuxProjectRowMetrics.rowHorizontalPadding)
            .frame(minHeight: metrics.compactRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SupermuxSidebarRowButtonStyle())
        .disabled(isPreparing)
        .accessibilityLabel(String(
            localized: "supermux.worktrees.new",
            defaultValue: "New Worktree",
            bundle: .module
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("SupermuxNestedNewWorktreeRow-\(projectID)")
    }
}

/// A nested row's placeholder line — the "nothing here yet" notice sits in
/// the nested column, so the disclosure never opens onto a left-aligned line
/// that ignores the section's alignment. (The loading state renders
/// ``SupermuxNestedSkeletonRow`` instead of a spinner variant of this row.)
struct SupermuxNestedNoticeRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text(text)
                .font(.system(.caption))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.trailing, SupermuxProjectRowMetrics.rowHorizontalPadding)
        .frame(minHeight: 32)
    }
}

/// The nested list rows under one project inside a SwiftUI `List` (macOS): the
/// project's open workspaces are ALWAYS visible, while its unopened worktrees
/// sit behind the disclosure.
///
/// Emits plain sibling rows for the host `Section` — each an immutable
/// snapshot plus closures, per the snapshot-boundary rule.
struct SupermuxProjectNestedRows: View {
    let row: SupermuxProjectRowSnapshot
    let actions: SupermuxProjectsSectionActions
    /// Whether the disclosure ends in the inline New Worktree row (host
    /// advertises `supermux.worktrees.v1`).
    var showsNewWorktree = false

    var body: some View {
        ForEach(row.openWorkspaces) { workspace in
            nested {
                SupermuxSidebarWorkspaceRow(
                    workspace: workspace,
                    selectWorkspace: actions.selectWorkspace,
                    closeWorkspace: actions.closeWorkspace
                )
            }
            // The `List` path's twin of the table path's custom swipe.
            .modifier(SupermuxWorkspaceListSwipeActions(
                workspaceID: workspace.id,
                closeWorkspace: actions.closeWorkspace
            ))
        }
        // `.unavailable` while collapsed (the model gates on isExpanded), so
        // the worktree slice renders only under an expanded project.
        switch row.nestedWorktrees {
        case .unavailable:
            EmptyView()
        case .loading:
            nested {
                SupermuxNestedSkeletonRow()
            }
        case .loaded(let worktrees):
            if worktrees.isEmpty, row.openWorkspaces.isEmpty, !showsNewWorktree {
                nested {
                    SupermuxNestedNoticeRow(text: String(
                        localized: "supermux.projects.nested.empty",
                        defaultValue: "No open workspaces or worktrees yet",
                        bundle: .module
                    ))
                }
            }
            ForEach(worktrees) { worktree in
                nested(symbol: "arrow.triangle.branch") {
                    SupermuxNestedWorktreeRow(
                        worktree: worktree,
                        open: { tapped in actions.openNestedWorktree(row.id, tapped) },
                        requestRemoval: { tapped in
                            actions.requestNestedWorktreeRemoval(row.id, tapped)
                        }
                    )
                }
                // The `List` path's twin of the table path's custom swipe: a
                // real `List` row gets the native modifier, so this container
                // is not left as the one place a worktree cannot be removed.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        actions.requestNestedWorktreeRemoval(row.id, worktree)
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
            }
            if showsNewWorktree {
                nested(symbol: "plus") {
                    SupermuxNestedNewWorktreeRow(
                        projectID: row.id,
                        isPreparing: actions.preparingNewWorktreeProjectID == row.id,
                        newWorktree: actions.requestNewWorktree
                    )
                }
            }
        }
    }

    /// Wraps one nested row in the shared alignment plus the `List`-only row
    /// modifiers this container path needs.
    private func nested(
        symbol: String? = nil,
        @ViewBuilder _ content: @escaping () -> some View
    ) -> some View {
        SupermuxNestedRowContainer(symbol: symbol, content: content)
            .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
            .listRowSeparator(.hidden)
    }
}

/// The nested workspace row's `List`-path swipe: the shell's close action, or
/// nothing at all when the host can't close workspaces.
///
/// A modifier rather than an inline `.swipeActions`, because the modifier can
/// return the untouched row in the unsupported case — `.swipeActions` with an
/// empty body still installs the gesture and reveals a blank tray.
private struct SupermuxWorkspaceListSwipeActions: ViewModifier {
    let workspaceID: String
    let closeWorkspace: (@MainActor (_ workspaceID: String) -> Void)?

    func body(content: Content) -> some View {
        if let closeWorkspace {
            content.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    closeWorkspace(workspaceID)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.workspaces.row.close",
                            defaultValue: "Close Workspace",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "xmark")
                    }
                }
            }
        } else {
            content
        }
    }
}

public import SwiftUI

/// One fork-owned row of the iPhone's merged workspace list: the PROJECTS
/// caption, a project, or a row of an expanded project's disclosure.
///
/// Each is its own table cell beside the shell's own workspace rows — the
/// list is ONE list, as on the Mac. Project and worktree rows keep the fork's
/// own swipe tray (``SupermuxSidebarSwipeRow``); the tray's open row lives on
/// the section model, so opening one closes every other cell's.
public struct SupermuxProjectsTableRowView: View {
    private let value: SupermuxProjectsTableRowValue
    private let actions: SupermuxProjectsSectionActions

    /// Creates the row.
    /// - Parameters:
    ///   - value: What the row draws.
    ///   - actions: The section's closure bundle.
    public init(value: SupermuxProjectsTableRowValue, actions: SupermuxProjectsSectionActions) {
        self.value = value
        self.actions = actions
    }

    /// Outer inset. The rows carry their own
    /// ``SupermuxProjectRowMetrics/rowHorizontalPadding`` inside their press
    /// plates; 4 + 10 lands the avatars two points inside the table's 12pt
    /// workspace margin.
    private static let horizontalInset: CGFloat = 4

    public var body: some View {
        content
            .padding(.horizontal, Self.horizontalInset)
            .padding(.vertical, SupermuxProjectRowMetrics.rowSpacing / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var openSwipeRowID: Binding<String?> {
        let actions = actions
        return Binding(get: { actions.openSwipeRowID() }, set: { actions.setOpenSwipeRowID($0) })
    }

    @ViewBuilder
    private var content: some View {
        switch value {
        case .header(let isCollapsed, let projectCount, let canEdit):
            SupermuxProjectsSectionHeader(
                isCollapsed: isCollapsed,
                projectCount: projectCount,
                toggleCollapsed: actions.toggleCollapsed,
                editing: canEdit ? actions.editing : nil
            )
        case .loading:
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
        case .empty(let canEdit):
            SupermuxProjectsEmptyState(editing: canEdit ? actions.editing : nil)
        case .project(let project):
            projectRow(project)
        case .worktree(let worktree):
            worktreeRow(worktree)
        case .worktreeLoading:
            SupermuxNestedRowContainer {
                SupermuxNestedSkeletonRow()
            }
        case .newWorktree(let projectRowID, let isPreparing):
            SupermuxNestedRowContainer(symbol: "plus") {
                SupermuxNestedNewWorktreeRow(
                    projectID: projectRowID,
                    isPreparing: isPreparing,
                    newWorktree: actions.requestNewWorktree
                )
            }
        case .notice:
            SupermuxNestedRowContainer {
                SupermuxNestedNoticeRow(text: String(
                    localized: "supermux.projects.nested.empty",
                    defaultValue: "No open workspaces or worktrees yet",
                    bundle: .module
                ))
            }
        }
    }

    private func projectRow(_ project: SupermuxMergedProjectRowValue) -> some View {
        let actions = actions
        let locationRowIDs = project.locationRowIDs
        return SupermuxSidebarSwipeRow(
            rowID: "project:\(project.key)",
            openRowID: openSwipeRowID,
            actions: projectSwipeActions(for: project)
        ) {
            SupermuxProjectMobileRow(
                row: project.display,
                iconPNGData: actions.iconPNGData,
                toggleExpanded: { _ in actions.toggleProjectsExpanded(locationRowIDs) },
                openWorkspace: actions.openProjectWorkspace,
                openDetail: actions.openProjectDetail,
                newWorktree: project.showsWorktreeCreation ? actions.requestNewWorktree : nil
            )
        }
    }

    /// A project row's swipe tray: New Worktree revealed first (the fork's
    /// most-used creation flow), then Project Details. The tray lays its
    /// actions out left-to-right in array order, so the FIRST-revealed action
    /// — the one on the trailing edge — is the LAST element.
    private func projectSwipeActions(for project: SupermuxMergedProjectRowValue) -> [SupermuxSwipeAction] {
        let actions = actions
        let rowID = project.display.id
        var trayActions: [SupermuxSwipeAction] = [
            SupermuxSwipeAction(
                id: "details",
                systemImage: "info.circle",
                title: String(
                    localized: "supermux.projects.row.details",
                    defaultValue: "Project Details",
                    bundle: .module
                ),
                tint: .gray,
                perform: { actions.openProjectDetail(rowID) }
            ),
        ]
        if project.showsWorktreeCreation {
            trayActions.append(SupermuxSwipeAction(
                id: "new-worktree",
                systemImage: "arrow.triangle.branch",
                title: String(
                    localized: "supermux.worktrees.new",
                    defaultValue: "New Worktree",
                    bundle: .module
                ),
                tint: .accentColor,
                perform: { actions.requestNewWorktree(rowID) }
            ))
        }
        return trayActions
    }

    /// An unopened worktree: swipe or long-press to remove it, routed through
    /// the same store the project detail screen uses.
    private func worktreeRow(_ value: SupermuxNestedWorktreeRowValue) -> some View {
        let actions = actions
        let projectRowID = value.projectRowID
        return SupermuxSidebarSwipeRow(
            rowID: "worktree:\(projectRowID):\(value.worktree.id)",
            openRowID: openSwipeRowID,
            actions: [
                SupermuxSwipeAction(
                    id: "remove",
                    systemImage: "trash",
                    title: SupermuxNestedWorktreeRow.removeTitle,
                    tint: .red,
                    isDestructive: true,
                    perform: { actions.requestNestedWorktreeRemoval(projectRowID, value.worktree) }
                ),
            ]
        ) {
            SupermuxNestedRowContainer(symbol: "arrow.triangle.branch") {
                HStack(spacing: 6) {
                    SupermuxNestedWorktreeRow(
                        worktree: value.worktree,
                        open: { tapped in actions.openNestedWorktree(projectRowID, tapped) },
                        requestRemoval: { tapped in actions.requestNestedWorktreeRemoval(projectRowID, tapped) }
                    )
                    if let macName = value.macName {
                        SupermuxNestedMacMarker(name: macName)
                            .padding(.trailing, SupermuxProjectRowMetrics.rowHorizontalPadding)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("SupermuxNestedWorktreeMac-\(value.worktree.id)")
                    }
                }
            }
        }
    }
}

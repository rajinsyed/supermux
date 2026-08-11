#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

/// The fork's Projects row rides in the workspace table's LEADING chrome run.
///
/// That placement is load-bearing, not cosmetic: `chromePrefixCount` counts
/// only a leading run of `.chrome` items, and the drag-reorder handler
/// subtracts it to convert a UIKit row index into an index in the SwiftUI
/// workspace model. If the Projects row ever stopped being counted — because it
/// stopped being `.chrome`, or because a non-chrome row was inserted above it —
/// dragging a workspace would silently move a DIFFERENT workspace, with every
/// existing range guard still passing. No prior test covered a non-zero prefix
/// at all (every fixture started at `.groupHeader`), so these pin it.
@Suite struct SupermuxProjectsTableRowTests {
    private let projects = WorkspaceListTableItem.chrome(.supermuxProjects)
    private let status = WorkspaceListTableItem.chrome(.macStatusRow)

    private func workspace(_ id: String) -> WorkspaceListTableItem {
        .workspace(.init(rawValue: id), indented: false)
    }

    /// Mirrors `WorkspaceListTableCoordinator.chromePrefixCount`.
    private func chromePrefixCount(_ items: [WorkspaceListTableItem]) -> Int {
        items.prefix { item in
            if case .chrome = item { return true }
            return false
        }.count
    }

    @Test func projectsRowIsCountedInTheChromePrefix() {
        let items = [status, projects, workspace("w1"), workspace("w2")]
        #expect(chromePrefixCount(items) == 2)
    }

    @Test func projectsRowIsCountedWithoutAnyConnectionChrome() {
        let items = [projects, workspace("w1")]
        #expect(chromePrefixCount(items) == 1)
    }

    @Test func reorderIndicesStayCorrectWithAProjectsRowPresent() {
        // The exact arithmetic from `performDropWith`.
        let items = [status, projects, workspace("w1"), workspace("w2"), workspace("w3")]
        let prefix = chromePrefixCount(items)
        let movableItemCount = items.count - prefix
        #expect(movableItemCount == 3, "only the three workspaces are movable")

        // Drag the SECOND workspace (UIKit row 3) onto the first (row 2).
        let source = 3 - prefix
        let destination = 2 - prefix
        #expect(source == 1, "row 3 is workspace index 1, not 3")
        #expect(destination == 0)
        #expect(source >= 0 && source < movableItemCount)
        #expect(destination >= 0 && destination <= movableItemCount)
    }

    @Test func theProjectsRowIsNeverADropTarget() {
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: projects,
            draggedItem: workspace("w1"),
            yOffset: 20,
            rowHeight: 44,
            canDropIntoGroup: true
        )
        #expect(decision == .forbidden)
    }

    @Test func theProjectsRowKeepsAStableIdentityAcrossUpdates() {
        // Project expansion must NOT change the item array, or the coordinator
        // treats it as structural and calls a whole-table reloadData(), which
        // would destroy the section's disclosure animation and hosted state.
        #expect(projects.id == "chrome.supermuxProjects")
        #expect(projects.workspaceID == nil)
        #expect(projects.groupID == nil)
        #expect(!projects.isIndentedWorkspace)
    }

    @Test func theProjectsRowIdDoesNotCollideWithOtherChrome() {
        let ids = Set([projects.id, status.id, WorkspaceListTableItem.chrome(.recoveryBanner).id])
        #expect(ids.count == 3)
    }
}
#endif

#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

/// The fork's merged Projects rows ride in the workspace table's LEADING run:
/// fork rows as `.chrome(.supermux(id))`, the workspaces nested under a
/// project as the shell's own `.workspace(id, indented: true)` rows.
///
/// That placement is load-bearing: `chromePrefixCount` counts the leading run,
/// and the drag-reorder handler subtracts it to convert a UIKit row index into
/// an index in the SwiftUI workspace model. A row of the block left out of the
/// count would make a drag move a DIFFERENT workspace, with every range guard
/// still passing.
@Suite struct SupermuxProjectsTableRowTests {
    private let header = WorkspaceListTableItem.chrome(.supermux("header"))
    private let project = WorkspaceListTableItem.chrome(.supermux("p:origin:github.com/acme/cmux"))
    private let status = WorkspaceListTableItem.chrome(.macStatusRow)

    private func workspace(_ id: String, indented: Bool = false) -> WorkspaceListTableItem {
        .workspace(.init(rawValue: id), indented: indented)
    }

    /// Mirrors `WorkspaceListTableCoordinator.chromePrefixCount`.
    private func chromePrefixCount(_ items: [WorkspaceListTableItem]) -> Int {
        items.prefix { item in
            if case .chrome = item { return true }
            if case .workspace(_, indented: true) = item { return true }
            return false
        }.count
    }

    @Test func theProjectBlockIsCountedInTheLeadingRun() {
        let items = [status, header, project, workspace("n1", indented: true), workspace("w1"), workspace("w2")]
        #expect(chromePrefixCount(items) == 4)
    }

    @Test func reorderIndicesSkipTheNestedRows() {
        // The exact arithmetic from `performDropWith`.
        let items = [header, project, workspace("n1", indented: true), workspace("w1"), workspace("w2"), workspace("w3")]
        let prefix = chromePrefixCount(items)
        let movableItemCount = items.count - prefix
        #expect(movableItemCount == 3, "only the three loose workspaces are movable")

        // Drag the SECOND loose workspace (UIKit row 4) onto the first (row 3).
        let source = 4 - prefix
        let destination = 3 - prefix
        #expect(source == 1, "row 4 is workspace index 1")
        #expect(destination == 0)
    }

    @Test func aGroupMemberAfterTheBlockIsNotCounted() {
        // Upstream's grouped output starts every group with its header, so an
        // indented row after the block never extends the leading run.
        let items = [header, project, workspace("n1", indented: true), .groupHeader("g"), workspace("m1", indented: true)]
        #expect(chromePrefixCount(items) == 3)
    }

    @Test func aProjectRowIsNeverADropTarget() {
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: project,
            draggedItem: workspace("w1"),
            yOffset: 20,
            rowHeight: 44,
            canDropIntoGroup: true
        )
        #expect(decision == .forbidden)
    }

    @Test func forkRowIdsAreNamespaced() {
        #expect(header.id == "chrome.supermux.header")
        #expect(header.workspaceID == nil)
        #expect(header.groupID == nil)
        let ids = Set([header.id, project.id, status.id, WorkspaceListTableItem.chrome(.recoveryBanner).id])
        #expect(ids.count == 4)
    }
}
#endif

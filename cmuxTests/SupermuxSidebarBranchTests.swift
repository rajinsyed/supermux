import XCTest
// `SidebarGitBranchState` is public in CmuxSidebar; import it explicitly (like
// SidebarOrderingTests) so this compiles in the plain-`cmux` unit config and not
// only when `cmux_DEV` happens to re-export it.
import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the supermux project-nested workspace row branch
/// subtitle (`SupermuxAppGlue`'s `SupermuxOpenWorkspace.branch`).
///
/// Bug: "the branch name in the workspace tab goes away when the browser tab is
/// open." The row used to read `workspace.gitBranch`, which only mirrors the
/// *focused* panel's branch — so focusing a branchless surface (a browser tab)
/// cleared it. The fix reads `workspace.supermuxSidebarBranch`, which derives
/// from the per-panel, display-ordered branches that persist across focus
/// changes (the same source cmux's own sidebar rows use).
@MainActor
final class SupermuxSidebarBranchTests: XCTestCase {
    func testSidebarBranchPersistsWhenBrowserTabIsFocused() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: terminalPanelId))

        workspace.updatePanelGitBranch(panelId: terminalPanelId, branch: "feature/x", isDirty: false)
        XCTAssertEqual(
            rowBranch(for: workspace),
            "feature/x",
            "Branch should display while the terminal is focused."
        )

        let browserPanel = try XCTUnwrap(
            workspace.newBrowserSurface(inPane: paneId, focus: true),
            "Expected the browser surface to be created."
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        // The repro condition: focusing a branchless browser clears the
        // workspace-level focused-branch mirror that the row used to read.
        XCTAssertNil(
            workspace.gitBranch,
            "Focusing a browser tab is expected to clear the focused-panel gitBranch mirror."
        )

        // The fix: the row the user sees must still carry the terminal's
        // branch, which persists per-panel regardless of which surface is
        // focused. Asserting the built snapshot (not the helper) guards the
        // actual SupermuxProjectsMount read-site that caused the bug.
        XCTAssertEqual(
            rowBranch(for: workspace),
            "feature/x",
            "Branch subtitle must persist when a browser tab is focused."
        )
    }

    func testSidebarBranchFallsBackToWorkspaceBranchWhenNoPanelReportsOne() throws {
        let workspace = Workspace(title: "Test")
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: false)

        XCTAssertEqual(
            rowBranch(for: workspace),
            "main",
            "With no per-panel branches, the row should fall back to the workspace-level branch."
        )
    }

    /// Renaming a project-nested workspace must re-title its row. The supermux
    /// "Rename Workspace…" action routes through `onRenameWorkspace` →
    /// `TabManager.setCustomTitle`, and the nested row reads
    /// `customTitle ?? title` via ``SupermuxWorkspaceRow/snapshot(for:isSelected:projectId:isRunning:)``.
    /// This guards that exact path, including the blank-name clear that reverts
    /// the row to the process title.
    func testSidebarTitleReflectsRenameAndBlankClears() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        // Baseline: with no custom title the row shows the process title.
        XCTAssertNil(workspace.customTitle)
        let processTitle = rowTitle(for: workspace)

        manager.setCustomTitle(tabId: workspace.id, title: "Renamed Workspace")
        XCTAssertEqual(workspace.customTitle, "Renamed Workspace")
        XCTAssertEqual(
            rowTitle(for: workspace),
            "Renamed Workspace",
            "The nested row must show the custom title after a rename."
        )

        // A blank/whitespace name clears the custom title (Workspace.setCustomTitle
        // trims to nil) and the row reverts to the process title.
        manager.setCustomTitle(tabId: workspace.id, title: "   ")
        XCTAssertNil(workspace.customTitle, "A blank rename clears the custom title.")
        XCTAssertEqual(
            rowTitle(for: workspace),
            processTitle,
            "Clearing the custom title reverts the row to the process title."
        )
    }

    /// The branch the user actually sees, built through the production
    /// ``SupermuxWorkspaceRow`` mapping used by ``SupermuxProjectsMount``.
    private func rowBranch(for workspace: Workspace) -> String? {
        SupermuxWorkspaceRow.snapshot(
            for: workspace,
            isSelected: false,
            projectId: nil,
            isRunning: false
        ).branch
    }

    /// The title the user actually sees on a project-nested row, built through
    /// the production ``SupermuxWorkspaceRow`` mapping used by ``SupermuxProjectsMount``.
    private func rowTitle(for workspace: Workspace) -> String {
        SupermuxWorkspaceRow.snapshot(
            for: workspace,
            isSelected: false,
            projectId: nil,
            isRunning: false
        ).title
    }
}

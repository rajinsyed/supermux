import XCTest

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
}

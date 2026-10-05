// SUPERMUX:begin sizing-hidden-terminal
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// A terminal hidden under another tab does not size the Mac: every request
/// that carries its grid, and so can attach the phone (a reconnect's replay,
/// a queued input), says `counts_override: false`, as its dedicated report
/// does. Shown again, only the dedicated report clears it (`null`).
@MainActor
@Suite struct SupermuxHiddenTerminalCountsTests {
    private let store = MobileShellComposite.preview()

    private func terminal() throws -> (MobileWorkspacePreview.ID, MobileTerminalPreview.ID) {
        let workspace = try #require(store.workspaces.first { !$0.terminals.isEmpty })
        let terminal = try #require(workspace.terminals.first)
        return (workspace.id, terminal.id)
    }

    private func report(_ workspaceID: MobileWorkspacePreview.ID, _ terminalID: MobileTerminalPreview.ID) {
        store.reportTerminalViewport(
            workspaceID: workspaceID,
            terminalID: terminalID,
            viewportSize: MobileTerminalViewportSize(columns: 60, rows: 30)
        )
    }

    @Test func hiddenTerminalPiggybackDoesNotCount() throws {
        let (workspaceID, terminalID) = try terminal()
        report(workspaceID, terminalID)
        store.supermuxSetTerminalCountsHidden(true, surfaceID: terminalID.rawValue)

        let params = store.terminalViewportParameters(workspaceID: workspaceID, terminalID: terminalID)
        #expect(params["viewport_columns"] as? Int == 60)
        #expect(params["counts_override"] as? Bool == false)
    }

    @Test func shownTerminalPiggybackLeavesCountsAlone() throws {
        let (workspaceID, terminalID) = try terminal()
        report(workspaceID, terminalID)
        store.supermuxSetTerminalCountsHidden(true, surfaceID: terminalID.rawValue)
        store.supermuxSetTerminalCountsHidden(false, surfaceID: terminalID.rawValue)

        // No `null`: a piggyback never clears an override the user set.
        let params = store.terminalViewportParameters(workspaceID: workspaceID, terminalID: terminalID)
        #expect(params["viewport_columns"] as? Int == 60)
        #expect(params["counts_override"] == nil)
    }

    @Test func hiddenTerminalWithoutGridSendsNoCounts() throws {
        let (workspaceID, terminalID) = try terminal()
        store.supermuxSetTerminalCountsHidden(true, surfaceID: terminalID.rawValue)

        // `counts_override` travels only with the grid it qualifies.
        #expect(store.terminalViewportParameters(workspaceID: workspaceID, terminalID: terminalID).isEmpty)
    }
}
// SUPERMUX:end sizing-hidden-terminal

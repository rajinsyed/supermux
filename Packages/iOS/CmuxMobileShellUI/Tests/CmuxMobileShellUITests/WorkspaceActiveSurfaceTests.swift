// SUPERMUX:begin supermux-mobile-selection-sync
import CMUXMobileCore
// SUPERMUX:end supermux-mobile-selection-sync
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceActiveSurfaceTests {
    @Test func chatTakesPrecedenceOverBrowserWhenSessionIsChosen() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: true,
            hasChosenChatSession: true,
            hasActiveBrowser: true
        ) == .chat)
    }

    @Test func browserTakesPrecedenceWhenChatHasNoChosenSession() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: true,
            hasChosenChatSession: false,
            hasActiveBrowser: true
        ) == .browser)
    }

    @Test func terminalIsDefaultSurface() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: false,
            hasChosenChatSession: false,
            hasActiveBrowser: false
        ) == .terminal)
    }

    @Test func browserStreamActivatesWhenNoLocalBrowserIsOpen() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: false,
            hasChosenChatSession: false,
            hasActiveBrowser: false,
            hasActiveBrowserStream: true
        ) == .browserStream)
    }

    @Test func simulatorStreamActivatesWhenNoBrowserSurfaceIsOpen() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: false,
            hasChosenChatSession: false,
            hasActiveBrowser: false,
            hasActiveBrowserStream: false,
            hasActiveSimulatorStream: true
        ) == .simulatorStream)
    }

    // SUPERMUX:begin ios-pane-actions
    @Test func paneCloseTargetsTheVisibleSurfaceKind() {
        #expect(WorkspaceActiveSurface.terminal.paneCloseTarget(
            selectedTerminalID: "terminal-1",
            browserStreamPanelID: nil,
            simulatorStreamPanelID: nil
        ) == .remote(panelID: "terminal-1"))
        #expect(WorkspaceActiveSurface.chat.paneCloseTarget(
            selectedTerminalID: "terminal-1",
            browserStreamPanelID: nil,
            simulatorStreamPanelID: nil
        ) == .remote(panelID: "terminal-1"))
        #expect(WorkspaceActiveSurface.browser.paneCloseTarget(
            selectedTerminalID: "terminal-1",
            browserStreamPanelID: nil,
            simulatorStreamPanelID: nil
        ) == .localBrowser)
        #expect(WorkspaceActiveSurface.browserStream.paneCloseTarget(
            selectedTerminalID: "terminal-1",
            browserStreamPanelID: "browser-1",
            simulatorStreamPanelID: nil
        ) == .remote(panelID: "browser-1"))
        #expect(WorkspaceActiveSurface.simulatorStream.paneCloseTarget(
            selectedTerminalID: "terminal-1",
            browserStreamPanelID: nil,
            simulatorStreamPanelID: "simulator-1"
        ) == .remote(panelID: "simulator-1"))
    }

    @Test func paneCloseRequiresAnIDForRemoteSurfaces() {
        #expect(WorkspaceActiveSurface.terminal.paneCloseTarget(
            selectedTerminalID: nil,
            browserStreamPanelID: nil,
            simulatorStreamPanelID: nil
        ) == nil)
        #expect(WorkspaceActiveSurface.browserStream.paneCloseTarget(
            selectedTerminalID: nil,
            browserStreamPanelID: nil,
            simulatorStreamPanelID: nil
        ) == nil)
        #expect(WorkspaceActiveSurface.simulatorStream.paneCloseTarget(
            selectedTerminalID: nil,
            browserStreamPanelID: nil,
            simulatorStreamPanelID: nil
        ) == nil)
    }
    // SUPERMUX:end ios-pane-actions

    @Test func chromeReturnRefocusesTheSelectedTerminal() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: "terminal-1",
            shouldAutoFocusTerminal: { _ in true },
            isComposerPresented: false
        ) == "terminal-1")
    }

    @Test func chromeReturnStaysSuppressedForChromeDrivenSwitches() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: "terminal-1",
            shouldAutoFocusTerminal: { _ in false },
            isComposerPresented: false
        ) == nil)
    }

    @Test func chromeReturnLeavesTheKeyboardWithAnOpenComposer() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: "terminal-1",
            shouldAutoFocusTerminal: { _ in true },
            isComposerPresented: true
        ) == nil)
    }

    @Test func chromeReturnWithoutATerminalDoesNothing() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: nil,
            shouldAutoFocusTerminal: { _ in true },
            isComposerPresented: false
        ) == nil)
    }

    // SUPERMUX:begin supermux-mobile-selection-sync
    @Test func focusedPanelPresentationResolvesEveryStreamedSurfaceKind() {
        #expect(WorkspaceFocusedPanelPresentationTarget.resolve(
            focusedPanel: .init(panelID: "terminal-1", kind: "terminal"),
            terminalIDs: ["terminal-1"],
            browserPanelIDs: [],
            simulatorPanelIDs: []
        ) == .terminal("terminal-1"))
        #expect(WorkspaceFocusedPanelPresentationTarget.resolve(
            focusedPanel: .init(panelID: "browser-1", kind: "browser"),
            terminalIDs: [],
            browserPanelIDs: ["browser-1"],
            simulatorPanelIDs: []
        ) == .browserStream("browser-1"))
        #expect(WorkspaceFocusedPanelPresentationTarget.resolve(
            focusedPanel: .init(panelID: "simulator-1", kind: "simulator"),
            terminalIDs: [],
            browserPanelIDs: [],
            simulatorPanelIDs: ["simulator-1"]
        ) == .simulatorStream("simulator-1"))
    }

    @Test func focusedPanelPresentationRejectsUnknownOrUndiscoveredPanels() {
        #expect(WorkspaceFocusedPanelPresentationTarget.resolve(
            focusedPanel: .init(panelID: "browser-missing", kind: "browser"),
            terminalIDs: [],
            browserPanelIDs: ["browser-1"],
            simulatorPanelIDs: []
        ) == .unsupported)
        #expect(WorkspaceFocusedPanelPresentationTarget.resolve(
            focusedPanel: .init(panelID: "future-1", kind: "markdown"),
            terminalIDs: [],
            browserPanelIDs: [],
            simulatorPanelIDs: []
        ) == .unsupported)
    }
    // SUPERMUX:end supermux-mobile-selection-sync
}

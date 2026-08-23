import CmuxMobileShellModel
import Foundation

// SUPERMUX:begin ios-pane-actions
/// The pane captured when the iOS close action is requested.
enum WorkspacePaneCloseTarget: Equatable {
    /// The phone-local fallback browser owned by ``BrowserSurfaceStore``.
    case localBrowser
    /// A terminal, streamed browser, Simulator, or future Mac panel.
    case remote(panelID: String)
}
// SUPERMUX:end ios-pane-actions

enum WorkspaceActiveSurface: Equatable {
    case terminal
    case browser
    case browserStream
    case simulatorStream
    case macSurface(MobileSurfacePreview)

    static func derive(
        hasActiveBrowser: Bool,
        hasActiveBrowserStream: Bool = false,
        hasActiveSimulatorStream: Bool = false,
        selectedMacSurface: MobileSurfacePreview? = nil
    ) -> Self {
        if hasActiveBrowser {
            return .browser
        }
        if hasActiveBrowserStream {
            return .browserStream
        }
        if hasActiveSimulatorStream {
            return .simulatorStream
        }
        if let selectedMacSurface { return .macSurface(selectedMacSurface) }
        return .terminal
    }

    // SUPERMUX:begin ios-pane-actions
    /// Resolves the exact pane targeted by the shared iOS close action.
    func paneCloseTarget(
        selectedTerminalID: String?,
        browserStreamPanelID: String?,
        simulatorStreamPanelID: String?
    ) -> WorkspacePaneCloseTarget? {
        switch self {
        case .terminal:
            return selectedTerminalID.map { .remote(panelID: $0) }
        case .browser:
            return .localBrowser
        case .browserStream:
            return browserStreamPanelID.map { .remote(panelID: $0) }
        case .simulatorStream:
            return simulatorStreamPanelID.map { .remote(panelID: $0) }
        case let .macSurface(surface):
            return .remote(panelID: surface.id.rawValue)
        }
    }
    // SUPERMUX:end ios-pane-actions

    /// The terminal to refocus when chrome (browser/stream) returns to the
    /// terminal surface, or nil when autofocus must stay suppressed.
    ///
    /// The terminal stays mounted under chrome (an opacity swap, not a
    /// remount), so the attach-time autofocus in `didMoveToWindow` never
    /// re-fires on return. This guard drives the explicit focus-on-return
    /// path with the same conditions as attach autofocus (`shouldAutoFocus`
    /// in `WorkspaceDetailView.detailContent()`): a chrome-suppressed
    /// terminal or an open composer must not have the keyboard grabbed for
    /// it.
    static func chromeReturnRefocusTerminalID(
        selectedTerminalID: String?,
        shouldAutoFocusTerminal: (String) -> Bool,
        isComposerPresented: Bool
    ) -> String? {
        guard let selectedTerminalID,
              shouldAutoFocusTerminal(selectedTerminalID),
              !isComposerPresented else { return nil }
        return selectedTerminalID
    }
}

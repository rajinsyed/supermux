// SUPERMUX:begin supermux-mobile-selection-sync
import CMUXMobileCore

/// The mobile surface that can present one Mac-authoritative focused panel.
enum WorkspaceFocusedPanelPresentationTarget: Equatable {
    case terminal(String)
    case browserStream(String)
    case simulatorStream(String)
    case unsupported

    static func resolve(
        focusedPanel: MobileWorkspaceFocusedPanel,
        terminalIDs: Set<String>,
        browserPanelIDs: Set<String>,
        simulatorPanelIDs: Set<String>
    ) -> Self {
        switch focusedPanel.kind {
        case MobileWorkspaceFocusedPanel.terminalKind
            where terminalIDs.contains(focusedPanel.panelID):
            return .terminal(focusedPanel.panelID)
        case MobileWorkspaceFocusedPanel.browserKind
            where browserPanelIDs.contains(focusedPanel.panelID):
            return .browserStream(focusedPanel.panelID)
        case MobileWorkspaceFocusedPanel.simulatorKind
            where simulatorPanelIDs.contains(focusedPanel.panelID):
            return .simulatorStream(focusedPanel.panelID)
        default:
            return .unsupported
        }
    }
}
// SUPERMUX:end supermux-mobile-selection-sync

import CMUXMobileCore
import CoreGraphics

struct WorkspaceTitleMenuValue: Equatable {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool
    let isEnabled: Bool
    let workspaceName: String
    let hasUnread: Bool
    let canCustomizeWorkspace: Bool
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    // SUPERMUX:begin ios-workspace-toolbar-persistent-actions
    /// Fingerprint of the workspace-tool menu rows (Changes/Files/alt-screen)
    /// hosted in the title menu, so `.equatable()` re-accepts the menu
    /// closure when any of them change. Defaults empty for hosts (previews,
    /// demo screens) with no tool entries.
    var toolEntriesFingerprint: String = ""
    // SUPERMUX:end ios-workspace-toolbar-persistent-actions
    let labelToken: WorkspaceTitleMenuLabelToken
    let terminalTheme: TerminalTheme
}

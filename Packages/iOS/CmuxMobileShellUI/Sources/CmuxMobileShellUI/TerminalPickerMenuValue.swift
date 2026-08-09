import CmuxMobileShellModel

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let isChatMode: Bool
    let browserStreamRows: [BrowserStreamPickerRow]
    let supportsBrowserStream: Bool
    let activeBrowserStreamPanelID: String?
    let simulatorStreamRows: [SimulatorStreamPickerRow]
    let supportsSimulatorStream: Bool
    let activeSimulatorStreamPanelID: String?
    // SUPERMUX:begin ios-pane-actions
    let canCreateSimulator: Bool
    let canClosePane: Bool
    // SUPERMUX:end ios-pane-actions

    init(
        liveTerminals: [MobileTerminalPreview],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?,
        canCreateWorkspace: Bool,
        hasActiveBrowser: Bool,
        isChatMode: Bool,
        browserStreamRows: [BrowserStreamPickerRow] = [],
        supportsBrowserStream: Bool = false,
        activeBrowserStreamPanelID: String? = nil,
        simulatorStreamRows: [SimulatorStreamPickerRow] = [],
        supportsSimulatorStream: Bool = false,
        activeSimulatorStreamPanelID: String? = nil,
        // SUPERMUX:begin ios-pane-actions
        canCreateSimulator: Bool = false,
        canClosePane: Bool = false
        // SUPERMUX:end ios-pane-actions
    ) {
        rows = snapshotRows.isEmpty
            ? liveTerminals.map(TerminalPickerMenuRow.init)
            : snapshotRows
        let selection = rows.resolvedTerminalPickerSelection(selectedID: selectedID)
        self.selectedID = selection?.id
        selectedName = selection?.name
        self.canCreateWorkspace = canCreateWorkspace
        self.hasActiveBrowser = hasActiveBrowser
        self.isChatMode = isChatMode
        self.browserStreamRows = browserStreamRows
        self.supportsBrowserStream = supportsBrowserStream
        self.activeBrowserStreamPanelID = activeBrowserStreamPanelID
        self.simulatorStreamRows = simulatorStreamRows
        self.supportsSimulatorStream = supportsSimulatorStream
        self.activeSimulatorStreamPanelID = activeSimulatorStreamPanelID
        // SUPERMUX:begin ios-pane-actions
        self.canCreateSimulator = canCreateSimulator
        self.canClosePane = canClosePane
        // SUPERMUX:end ios-pane-actions
    }
}

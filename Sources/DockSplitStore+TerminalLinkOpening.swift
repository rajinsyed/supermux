import AppKit
import CmuxPanes
import Foundation

extension DockSplitStore: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "dock:\(workspaceId.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId) else {
            return nil
        }
        return terminalWorkingDirectory(for: panelId)
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        // An unplaced source may be any terminal, so it never resolves locally.
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId) else {
            return true
        }
        if detachedSurfaceTransfersByPanelId[panelId]?.isRemoteTerminal == true { return true }
        return machineOwningSurface(panelId)?.isLocal != true
    }

    // SUPERMUX:begin device-terminal-file-link (a path in another Mac's terminal in the Dock opens that Mac's file)
    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool {
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId),
              let workspace = Workspace.liveWorkspace(id: workspaceId) else { return false }
        return SupermuxDeviceTerminalLinks.open(rawValue, panelID: panelId, in: workspace)
    }
    // SUPERMUX:end device-terminal-file-link

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        guard let resource = SurfaceCatalog.shared.resource(forPanel: sourcePanelId),
              let address = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.privateAddress,
              let target = CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(url: url, resource: resource, privateAddress: address) else { return nil }
        return target
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId _: UUID,
        filePath _: String,
        fallback _: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        // The Dock currently hosts terminal and browser panels only. Returning
        // false makes the shared coordinator hand the resolved file to macOS.
        false
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool = true) -> Bool {
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId),
              let sourcePane = paneId(forPanelId: panelId) else { return false }
        if let targetPane = BrowserRightSidePaneResolver().preferredPane(
            from: sourcePane,
            in: bonsplitController
        ) {
            if focus { noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow) }
            guard let panelId = newSurface(
                kind: .browser,
                inPane: targetPane,
                url: url,
                focus: false
            ) else { return false }
            if focus { focusPanelFromDockInteraction(
                panelId,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            ) }
            return true
        }
        if focus { noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow) }
        guard let panelId = newSplit(
            kind: .browser,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: panelId,
            url: url,
            focus: false
        ) else { return false }
        if focus { focusPanelFromDockInteraction(
            panelId,
            window: NSApp.keyWindow ?? NSApp.mainWindow
        ) }
        return true
    }
}

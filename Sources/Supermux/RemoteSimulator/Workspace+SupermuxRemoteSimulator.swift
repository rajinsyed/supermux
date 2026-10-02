import Bonsplit
import CmuxSurfaceCatalogModel
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// A remote-simulator viewer tab (``SupermuxRemoteSimulatorPanel``) in
    /// `paneId`, made the way `newSimulatorSurface` makes a local Simulator
    /// tab: same title, icon and tab kind, and the same focus handling.
    @discardableResult
    func newSupermuxRemoteSimulatorSurface(
        inPane paneId: PaneID,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String,
        hostPanelID: UUID? = nil,
        deviceUDID: String? = nil,
        focus: Bool
    ) -> SupermuxRemoteSimulatorPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView
        let panel = SupermuxRemoteSimulatorPanel(
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            hostPanelID: hostPanelID,
            deviceUDID: deviceUDID,
            workspace: self
        )
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.simulator.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }

        bindSurface(tabId, toPanelId: panel.id)
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: SurfaceKind.simulator.rawValue,
            origin: "supermux_remote_simulator_tab",
            focused: focus
        )

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: previousHostedView
            )
        }
        return panel
    }
}

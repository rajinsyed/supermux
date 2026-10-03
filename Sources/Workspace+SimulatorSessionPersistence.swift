import Bonsplit
import CmuxWorkspaces
import Foundation

struct SessionSimulatorPanelSnapshot: Codable, Sendable {
    var deviceUDID: String?
    var runtimeIdentifier: String?
    var deviceTypeIdentifier: String?
    // SUPERMUX:begin remote-simulator-session
    /// A device mirror's viewer of another Mac's simulator (nil for a local one).
    var supermuxRemote: SupermuxRemoteSimulatorSnapshot?
    // SUPERMUX:end remote-simulator-session
}

extension Workspace {
    func simulatorSessionSnapshot(for panel: any Panel) -> SessionSimulatorPanelSnapshot? {
        // SUPERMUX:begin remote-simulator-session
        if let viewer = panel as? SupermuxRemoteSimulatorPanel { return viewer.sessionSnapshot() }
        // SUPERMUX:end remote-simulator-session
        guard let simulatorPanel = panel as? SimulatorPanel else { return nil }
        return SessionSimulatorPanelSnapshot(
            deviceUDID: simulatorPanel.selectedDeviceID,
            runtimeIdentifier: simulatorPanel.selectedRuntimeIdentifier,
            deviceTypeIdentifier: simulatorPanel.selectedDeviceTypeIdentifier
        )
    }

    func restoreSimulatorPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID
    ) -> UUID? {
        // SUPERMUX:begin remote-simulator-session
        // A mirror's simulator runs on the Mac that owns the workspace: a saved
        // viewer tab, or an older build's local Simulator in a mirror, comes
        // back as a viewer and never boots a simulator here.
        if snapshot.simulator?.supermuxRemote != nil || SupermuxRemoteSimulators.blocksLocalSimulator(in: self) {
            return SupermuxRemoteSimulators.shared.restore(snapshot, inPane: paneId, in: self)
        }
        // SUPERMUX:end remote-simulator-session
        guard let simulatorPanel = newSimulatorSurface(
            inPane: paneId,
            preferredDeviceID: snapshot.simulator?.deviceUDID,
            preferredRuntimeIdentifier: snapshot.simulator?.runtimeIdentifier,
            preferredDeviceTypeIdentifier: snapshot.simulator?.deviceTypeIdentifier,
            focus: false,
            restoringSession: true
        ) else {
            return nil
        }
        applySessionPanelMetadata(snapshot, toPanelId: simulatorPanel.id)
        return simulatorPanel.id
    }
}

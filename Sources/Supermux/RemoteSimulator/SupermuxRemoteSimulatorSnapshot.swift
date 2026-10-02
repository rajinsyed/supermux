import Bonsplit
import Foundation
import SupermuxKit

/// What a saved session keeps of a remote-simulator viewer tab: the
/// `supermuxRemote` field of upstream's `SessionSimulatorPanelSnapshot` (the
/// `remote-simulator-session` touchpoint). The upstream device fields stay
/// empty, so an older build restores the tab as a local Simulator that boots
/// nothing until a device is picked.
struct SupermuxRemoteSimulatorSnapshot: Codable, Sendable, Equatable {
    /// The Mac the simulator runs on (`device:<uuid>@<tag>`).
    var machine: String
    var remoteWorkspaceID: String
    /// The host panel it showed; that Mac gives its panels new ids when it
    /// restarts, so the device below finds it again.
    var hostPanelID: String?
    var deviceUDID: String?
}

extension SupermuxRemoteSimulatorPanel {
    /// The viewer as a session saves it.
    func sessionSnapshot() -> SessionSimulatorPanelSnapshot {
        SessionSimulatorPanelSnapshot(
            deviceUDID: nil,
            runtimeIdentifier: nil,
            deviceTypeIdentifier: nil,
            supermuxRemote: SupermuxRemoteSimulatorSnapshot(
                machine: machine.rawValue,
                remoteWorkspaceID: remoteWorkspaceID,
                hostPanelID: hostPanelID?.uuidString,
                deviceUDID: deviceUDID
            )
        )
    }
}

extension SupermuxRemoteSimulators {
    /// A saved viewer tab, or an older build's local Simulator saved in a
    /// mirror, comes back as a viewer that waits for the link and then finds
    /// its simulator again (``rebind(_:create:)``). Called from the
    /// `remote-simulator-session` touchpoint; never makes a local simulator.
    func restore(_ snapshot: SessionPanelSnapshot, inPane paneId: PaneID, in workspace: Workspace) -> UUID? {
        let saved = snapshot.simulator?.supermuxRemote
        let ref = saved.map { SupermuxRemoteWorkspaceRef(machineID: $0.machine, workspaceID: $0.remoteWorkspaceID) }
            ?? mirroredRef(of: workspace)
        guard let ref, ref.machine.isDevice,
              let panel = workspace.newSupermuxRemoteSimulatorSurface(
                  inPane: paneId,
                  machine: ref.machine,
                  remoteWorkspaceID: ref.workspaceID,
                  hostPanelID: saved?.hostPanelID.flatMap(UUID.init(uuidString:)),
                  deviceUDID: saved?.deviceUDID ?? snapshot.simulator?.deviceUDID,
                  focus: false
              ) else { return nil }
        workspace.applySessionPanelMetadata(snapshot, toPanelId: panel.id)
        panel.rebindWhenLinked()
        return panel.id
    }
}

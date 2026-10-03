import Foundation
import SupermuxKit

/// Answers "is this local workspace a device mirror, and of what?" for the
/// fork's workspace-scoped features. Built on the foundation's workspace
/// index, so a workspace that merely borrows one remote pane stays local.
///
/// ```swift
/// if let target = SupermuxComposition.mirrorResolver.target(for: workspace) {
///     // route to target.machine / target.remoteWorkspaceID
/// }
/// ```
@MainActor
struct SupermuxMirrorResolver {
    let devices: SupermuxDevices
    let index: SupermuxDeviceWorkspaceIndex

    /// The remote workspace `workspace` mirrors, or `nil` for a local workspace.
    func target(for workspace: Workspace?) -> SupermuxMirrorTarget? {
        guard let workspace, index.isDeviceMirror(workspace), let ref = index.ref(forLocal: workspace) else {
            return nil
        }
        let record = devices.record(for: ref)
        let device = devices.device(for: ref.machine)
        return SupermuxMirrorTarget(
            ref: ref,
            localWorkspaceID: workspace.id,
            deviceName: device?.displayName ?? String(
                localized: "supermux.mirror.otherMac",
                defaultValue: "the other Mac"
            ),
            isConnected: device?.isConnected ?? false,
            remoteWorkspaceID: record?.id ?? ref.workspaceID,
            remoteDirectory: record?.currentDirectory,
            remoteProjectID: record?.supermuxProjectID
        )
    }

    /// The remote workspace a local workspace id mirrors, if it is a live mirror.
    func target(forWorkspaceID id: UUID) -> SupermuxMirrorTarget? {
        target(for: Workspace.liveWorkspace(id: id))
    }
}

import Foundation
import SupermuxKit

/// Builds the nested Projects-section row for a device mirror: the local
/// workspace's own snapshot, plus what only the other Mac knows — its device
/// chip, run state, and branch from the remote record when the mirror has
/// none of its own. Activity comes only from the snapshot, whose resolver reads
/// the status projection: it shows no live activity for an offline Mac, while
/// the record still holds the last synced value.
///
/// The record's branch comes from ``SupermuxUnifiedProjectsModel/mirrorRemoteFields``
/// (observable, reassigned only on a real change), not from the device's
/// records, so the sidebar body never follows ``SupermuxDevices/revision``.
@MainActor
enum SupermuxMirrorRowSnapshot {
    static func snapshot(
        for workspace: Workspace,
        isSelected: Bool,
        projectId: UUID,
        unreadCount: Int
    ) -> SupermuxOpenWorkspace {
        let base = SupermuxWorkspaceRow.snapshot(
            for: workspace,
            isSelected: isSelected,
            projectId: projectId,
            isRunning: false,
            unreadCount: unreadCount
        )
        guard let ref = SupermuxComposition.deviceWorkspaceIndex.ref(forLocal: workspace) else { return base }
        let remoteFields = SupermuxComposition.unifiedProjects.mirrorRemoteFields[workspace.id]
        let device = SupermuxComposition.devices.device(for: ref.machine)
        let remote = SupermuxComposition.remoteProjects.device(ref.machine)
        return SupermuxOpenWorkspace(
            id: base.id,
            title: base.title,
            // The mirror's local directory is not the remote path; an empty
            // directory keeps it from hiding a same-path LOCAL worktree row.
            directory: "",
            isSelected: base.isSelected,
            branch: base.branch ?? remoteFields?.branch,
            projectId: projectId,
            activity: base.activity,
            isRunning: remote?.isRunning(remoteWorkspaceID: ref.workspaceID) ?? false,
            unreadCount: base.unreadCount,
            device: SupermuxProjectDevice(
                machineID: ref.machineID,
                name: device?.displayName ?? remote?.name ?? ref.machineID,
                isOnline: device?.isConnected ?? false
            )
        )
    }
}

import CMUXMobileCore
import Foundation
import SupermuxKit

/// Builds the nested Projects-section row for a device mirror: the local
/// workspace's own snapshot, plus what only the other Mac knows — its device
/// chip, run state, and branch / PR from the remote record when the mirror has
/// none of its own. Activity comes only from the snapshot, whose resolver reads
/// the status projection: it shows no live activity for an offline Mac, while
/// the record still holds the last synced value.
@MainActor
enum SupermuxMirrorRowSnapshot {
    static func snapshot(
        for workspace: Workspace,
        isSelected: Bool,
        projectId: UUID,
        includePullRequest: Bool,
        unreadCount: Int,
        showsStatus: Bool = false,
        showsProgress: Bool = false
    ) -> SupermuxOpenWorkspace {
        let base = SupermuxWorkspaceRow.snapshot(
            for: workspace,
            isSelected: isSelected,
            projectId: projectId,
            isRunning: false,
            includePullRequest: includePullRequest,
            unreadCount: unreadCount,
            showsStatus: showsStatus,
            showsProgress: showsProgress
        )
        let index = SupermuxComposition.deviceWorkspaceIndex
        guard let ref = index.ref(forLocal: workspace) else { return base }
        let record = index.record(for: ref)
        let device = SupermuxComposition.devices.device(for: ref.machine)
        let remote = SupermuxComposition.remoteProjects.device(ref.machine)
        return SupermuxOpenWorkspace(
            id: base.id,
            title: base.title,
            // The mirror's local directory is not the remote path; an empty
            // directory keeps it from hiding a same-path LOCAL worktree row.
            directory: "",
            isSelected: base.isSelected,
            branch: base.branch ?? record?.supermuxBranch,
            projectId: projectId,
            activity: base.activity,
            isRunning: remote?.isRunning(remoteWorkspaceID: ref.workspaceID) ?? false,
            pullRequest: base.pullRequest ?? (includePullRequest ? pullRequest(record?.supermuxPullRequest) : nil),
            unreadCount: base.unreadCount,
            device: SupermuxProjectDevice(
                machineID: ref.machineID,
                name: device?.displayName ?? remote?.name ?? ref.machineID,
                isOnline: device?.isConnected ?? false
            ),
            // The pills and progress the status projection wrote into the
            // mirror are its Mac's (the flat mirror row shows the same).
            statusPills: base.statusPills,
            progress: base.progress
        )
    }

    private static func pullRequest(_ wire: WorkspaceSyncRecord.SupermuxPullRequest?) -> SupermuxPullRequest? {
        guard let wire,
              let number = wire.number,
              let state = wire.state,
              let status = SupermuxPullRequest.Status(rawValue: state),
              let raw = wire.url,
              let url = URL(string: raw) else { return nil }
        return SupermuxPullRequest(number: number, status: status, url: url, isStale: wire.isStale ?? false)
    }
}

import CMUXMobileCore
import Foundation
import SupermuxKit

/// Builds the nested Projects-section row for a device mirror: the local
/// workspace's own snapshot, plus what only the other Mac knows — its device
/// chip, and branch / PR / activity / run state from the remote record when
/// the mirror has none of its own.
@MainActor
enum SupermuxMirrorRowSnapshot {
    static func snapshot(
        for workspace: Workspace,
        isSelected: Bool,
        projectId: UUID,
        includePullRequest: Bool,
        unreadCount: Int
    ) -> SupermuxOpenWorkspace {
        let base = SupermuxWorkspaceRow.snapshot(
            for: workspace,
            isSelected: isSelected,
            projectId: projectId,
            isRunning: false,
            includePullRequest: includePullRequest,
            unreadCount: unreadCount
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
            activity: base.activity != .idle ? base.activity : activity(record?.supermuxActivity),
            isRunning: remote?.isRunning(remoteWorkspaceID: ref.workspaceID) ?? false,
            pullRequest: base.pullRequest ?? (includePullRequest ? pullRequest(record?.supermuxPullRequest) : nil),
            unreadCount: base.unreadCount,
            device: SupermuxProjectDevice(
                machineID: ref.machineID,
                name: device?.displayName ?? remote?.name ?? ref.machineID,
                isOnline: device?.isConnected ?? false
            )
        )
    }

    /// The wire activity (`working` / `needs_input` / `ready`).
    private static func activity(_ raw: String?) -> SupermuxWorkspaceActivity {
        switch raw {
        case "working": return .working
        case "needs_input": return .needsInput
        case "ready": return .ready
        default: return .idle
        }
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

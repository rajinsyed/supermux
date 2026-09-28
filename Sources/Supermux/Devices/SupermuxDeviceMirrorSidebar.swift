import CmuxSidebar
import Foundation
import SupermuxKit

/// Flat sidebar row overlays for device mirrors, read by the
/// `device-mirror-flatrow-status` touchpoint in
/// `SidebarWorkspaceSnapshotFactory`: git never probes a mirror's panes, so
/// its branch and PR come from the remote record (``SupermuxDeviceStatusProjector``).
/// Empty / nil for every local workspace.
@MainActor
enum SupermuxDeviceMirrorSidebar {
    /// The remote branch of a mirror.
    static func branch(for workspace: Workspace) -> String? {
        SupermuxComposition.deviceStatusProjector.status(forLocal: workspace.id)?.branch
    }

    /// The remote PR row of a mirror.
    static func pullRequestDisplays(for workspace: Workspace) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        guard let pullRequest = SupermuxComposition.deviceStatusProjector.status(forLocal: workspace.id)?.pullRequest,
              let status = SidebarPullRequestStatus(rawValue: pullRequest.status.rawValue) else { return [] }
        let label = String(localized: "supermux.devices.mirror.pullRequestLabel", defaultValue: "PR")
        return [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
            id: "supermux-remote#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
            number: pullRequest.number,
            label: label,
            url: pullRequest.url,
            status: status,
            isStale: pullRequest.isStale
        )]
    }
}

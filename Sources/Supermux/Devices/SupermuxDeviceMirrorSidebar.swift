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

    /// A mirror's directory line: its panes' directories on the other Mac,
    /// without the "<Mac> · " prefix upstream's cloud presentation adds (the
    /// row's device chip names the Mac). Paths stay as the other Mac reports
    /// them — this Mac's home never abbreviates them and the other Mac's home
    /// is not known. Longest form first, like upstream's candidates. Nil for
    /// every workspace that is not a device mirror.
    static func directoryCandidates(
        for workspace: Workspace,
        orderedPanelIds: [UUID],
        usesLastSegmentPath: Bool
    ) -> [String]? {
        guard SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) else { return nil }
        var seen = Set<String>()
        let directories = orderedPanelIds
            .filter { workspace.terminalPanel(for: $0) != nil }
            .compactMap { workspace.reportedPanelDirectory(panelId: $0) }
            .filter { seen.insert($0).inserted }
        let unavailable = CloudWorkspaceSidebarPresentation.unavailableDirectory
        guard !directories.isEmpty else { return [unavailable] }
        let paths = directories.map { directory in
            usesLastSegmentPath ? SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: "") : [directory]
        }
        let full = paths.map { $0.first ?? unavailable }.joined(separator: ", ")
        let compact = paths.map { $0.last ?? unavailable }.joined(separator: ", ")
        return full == compact ? [full] : [full, compact]
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

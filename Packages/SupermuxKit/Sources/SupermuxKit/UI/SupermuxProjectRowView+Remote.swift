import SwiftUI

/// A local project row's other-Mac parts: device copies' unopened worktrees
/// (with device chips), "Open on ▸ <Mac>" when the project lives on more than
/// one Mac, remote worktrees in the Worktrees menu, and "Set Up on <Mac>…".
extension SupermuxProjectRowView {
    /// Unopened worktrees of the device copies (loaded when the row expands).
    var remoteWorktrees: [SupermuxRemoteWorktree] { remoteExtras?.worktrees ?? [] }

    /// Whether the worktree disclosure pill shows: something to reveal here,
    /// or a reachable device copy whose worktrees load on expansion.
    var showsWorktreeDisclosure: Bool {
        worktreeDisclosureCount > 0
            || (remoteExtras?.project.remoteLocations.contains(where: \.isOnline) ?? false)
    }

    /// The pill's count: this Mac's unopened worktrees plus loaded remote ones.
    var worktreeDisclosureCount: Int { unopenedWorktrees.count + remoteWorktrees.count }

    @ViewBuilder
    var remoteWorktreeRows: some View {
        ForEach(remoteWorktrees) { worktree in
            SupermuxRemoteWorktreeRowView(
                worktree: worktree,
                open: { remoteActions.openWorktree(worktree) },
                delete: { deleteBranch in remoteActions.removeWorktree(worktree, deleteBranch) },
                openPullRequest: { url in actions.openPullRequest(url, nil) }
            )
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// "Open on ▸" listing every Mac with a copy (only when there are several).
    @ViewBuilder
    var openOnMenu: some View {
        if let extras = remoteExtras, extras.project.locations.count > 1 {
            Menu(String(localized: "supermux.project.openOnMenu", defaultValue: "Open on")) {
                ForEach(extras.project.locations) { location in
                    if let device = location.device {
                        Button(device.name) { remoteActions.openProject(location) }
                            .disabled(!device.isOnline)
                    } else {
                        Button(String(localized: "supermux.devices.thisMac", defaultValue: "This Mac"), action: actions.openLocal)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var remoteWorktreeMenuItems: some View {
        if !remoteWorktrees.isEmpty {
            Divider()
            SupermuxRemoteWorktreeMenuItems(worktrees: remoteWorktrees, actions: remoteActions)
        }
    }

    @ViewBuilder
    var setUpMenuItems: some View {
        if let targets = remoteExtras?.setUpTargets, !targets.isEmpty {
            ForEach(targets, id: \.self) { destination in
                Button(String(localized: "supermux.project.setUpOn", defaultValue: "Set Up on \(destination.name)…")) {
                    setUp(destination)
                }
            }
        }
    }
}

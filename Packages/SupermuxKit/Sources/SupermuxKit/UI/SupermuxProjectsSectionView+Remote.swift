import AppKit
import SwiftUI

/// The Projects section's other-Mac parts: remote-only project rows (after
/// the local projects), lazy loading of device worktrees on expansion, and the
/// remote New Worktree / "Set Up on <Mac>…" sheets.
extension SupermuxProjectsSectionView {
    /// Remote-only projects, each with the mirrors it owns nested under it.
    @ViewBuilder
    func remoteProjectRows(grouped: [UUID: [SupermuxOpenWorkspace]]) -> some View {
        ForEach(remote.rows) { row in
            SupermuxRemoteProjectRowView(
                row: row,
                openWorkspaces: grouped[row.id] ?? [],
                isExpanded: expandedRemoteProjectIds.contains(row.id),
                actions: remote.actions,
                toggleExpanded: { toggleRemoteExpanded(row) },
                newWorktree: {
                    remoteNewWorktreeTarget = SupermuxRemoteNewWorktreeTarget(
                        location: row.location,
                        projectName: row.project.name,
                        avatar: row.avatar,
                        icon: row.icon
                    )
                },
                setUp: { destination in
                    projectSetupTarget = SupermuxProjectSetupTarget(
                        projectName: row.project.name,
                        destination: destination,
                        defaultPath: row.location.rootPath,
                        remoteURL: row.remoteURL
                    )
                },
                selectWorkspace: onSelectWorkspace,
                closeWorkspace: onCloseWorkspace,
                renameWorkspace: { promptRenameWorkspace(id: $0) },
                openPullRequest: onOpenPullRequest
            )
        }
    }

    /// Toggles a remote-only project's worktree disclosure, loading that
    /// Mac's worktrees on open.
    func toggleRemoteExpanded(_ row: SupermuxRemoteProjectRow) {
        if expandedRemoteProjectIds.contains(row.id) {
            expandedRemoteProjectIds.remove(row.id)
        } else {
            expandedRemoteProjectIds.insert(row.id)
            remote.actions.loadWorktrees(row.location)
        }
    }

    /// Loads the device copies' worktrees when a local project row expands.
    func loadRemoteWorktrees(forLocalProject id: UUID) {
        guard let extras = remote.extrasByLocalProjectID[id] else { return }
        for location in extras.project.remoteLocations where location.isOnline {
            remote.actions.loadWorktrees(location)
        }
    }

    /// Presents "Set Up on <Mac>…" for a local project.
    func presentSetUp(project: SupermuxProject, destination: SupermuxProjectSetupDestination) {
        projectSetupTarget = SupermuxProjectSetupTarget(
            projectName: project.name,
            destination: destination,
            defaultPath: project.rootPath,
            remoteURL: remote.extrasByLocalProjectID[project.id]?.remoteURL
        )
    }

    /// Hosts the remote sheets on their own view, so they never compete with
    /// the section's own `.sheet` modifiers.
    var remoteSheetsAnchor: some View {
        let actions = remote.actions
        return Color.clear
            .sheet(item: $remoteNewWorktreeTarget) { target in
                SupermuxRemoteNewWorktreeSheet(target: target) { request in
                    try await actions.createWorktree(target.location, request)
                }
            }
            .sheet(item: $projectSetupTarget) { target in
                SupermuxProjectSetupSheet(
                    target: target,
                    addExisting: { path in try await actions.addExistingFolder(target.destination, path) },
                    clone: { url, path in try await actions.cloneRepository(target.destination, url, path) }
                )
            }
    }
}

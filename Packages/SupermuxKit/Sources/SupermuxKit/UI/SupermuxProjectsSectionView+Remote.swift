import AppKit
import SwiftUI

/// The Projects section's other-Mac parts: remote-only project rows (drawn
/// among the local projects in the shared order), a device worktree load on
/// expansion (a backstop: every refresh already loads them), and the
/// "Set Up on <Mac>…" sheet.
extension SupermuxProjectsSectionView {
    /// A remote-only project with the mirrors it owns nested under it. It
    /// drags and takes drops like a local project row; a drop sends the move
    /// to the Macs that hold it.
    /// - Parameters:
    ///   - row: The remote-only project.
    ///   - grouped: The nested rows by unified project id.
    ///   - baseOrder: The drawn order without a drag preview.
    func remoteProjectRow(
        _ row: SupermuxRemoteProjectRow,
        grouped: [UUID: [SupermuxOpenWorkspace]],
        baseOrder: [UUID]
    ) -> some View {
        SupermuxRemoteProjectRowView(
            row: row,
            openWorkspaces: grouped[row.id] ?? [],
            isExpanded: expandedRemoteProjectIds.contains(row.id),
            actions: remote.actions,
            toggleExpanded: { toggleRemoteExpanded(row) },
            newWorktree: { presentNewWorktree(forRemote: row) },
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
            beginDrag: { beginProjectDrag(row.id) },
            dropDelegate: projectDropDelegate(for: row.id, baseOrder: baseOrder),
            draggingProjectId: draggingProjectId,
            pendingWorktrees: pendingRows(for: row.id),
            pendingActions: pendingActions
        )
    }

    /// Toggles a remote-only project's worktree disclosure, loading that
    /// Mac's worktrees on open if no refresh has yet.
    func toggleRemoteExpanded(_ row: SupermuxRemoteProjectRow) {
        if expandedRemoteProjectIds.contains(row.id) {
            expandedRemoteProjectIds.remove(row.id)
        } else {
            expandedRemoteProjectIds.insert(row.id)
            remote.actions.loadWorktrees(row.location)
        }
    }

    /// Loads the device copies' worktrees when a local project row expands,
    /// if no refresh has yet.
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

    /// Hosts the setup sheet on its own view, so it never competes with the
    /// section's own `.sheet` modifiers.
    var remoteSheetsAnchor: some View {
        let actions = remote.actions
        return Color.clear
            .sheet(item: $projectSetupTarget) { target in
                SupermuxProjectSetupSheet(
                    target: target,
                    addExisting: { path in try await actions.addExistingFolder(target.destination, path) },
                    clone: { url, path in try await actions.cloneRepository(target.destination, url, path) }
                )
            }
    }
}

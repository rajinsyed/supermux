import AppKit
import SwiftUI

/// The item that presents ``SupermuxNewWorktreeSheet``.
struct SupermuxNewWorktreeSheetItem: Identifiable {
    let id = UUID()
    let model: SupermuxNewWorktreeSheetModel
    /// The sidebar project row the create shows under while it runs.
    let rowID: UUID
    /// The project record the header avatar renders.
    let avatar: SupermuxProject
    let icon: NSImage?
}

/// Presents the one New Worktree sheet from every entry point: a local
/// project row (hover ＋, context menu, "New Worktree on ▸ <Mac>") and a
/// remote-only row. The sheet's device picker lists every Mac with the
/// project; a "Set Up on <Mac>…" row hands off to the setup sheet. Create
/// runs in the background (``SupermuxPendingWorktreeStore``): the sheet closes
/// at once and the project row shows the create until its workspace is open.
extension SupermuxProjectsSectionView {
    /// Opens the sheet for a project with a copy on this Mac.
    /// - Parameter preferredDeviceKey: The Mac picked from "New Worktree on ▸",
    ///   or `nil` for the last Mac used with this project.
    func presentNewWorktree(forLocal project: SupermuxProject, preferredDeviceKey: String? = nil) {
        let remoteURL = remote.extrasByLocalProjectID[project.id]?.remoteURL
        let sheetModel = remote.newWorktreeSheetModel(
            context: remote.newWorktreeContext(forLocal: project),
            preferredDeviceKey: preferredDeviceKey,
            localTarget: { localWorktreeTarget(for: project) },
            onSetUp: { destination in
                handOffToSetUp(SupermuxProjectSetupTarget(
                    projectName: project.name,
                    destination: destination,
                    defaultPath: project.rootPath,
                    remoteURL: remoteURL
                ))
            }
        )
        newWorktreeSheet = SupermuxNewWorktreeSheetItem(
            model: sheetModel,
            rowID: project.id,
            avatar: project,
            icon: iconStore.image(for: project.id)
        )
    }

    /// Opens the sheet for a project that exists only on other Macs.
    func presentNewWorktree(forRemote row: SupermuxRemoteProjectRow) {
        let sheetModel = remote.newWorktreeSheetModel(
            context: remote.newWorktreeContext(forRemote: row),
            preferredDeviceKey: nil,
            localTarget: { nil },
            onSetUp: { destination in
                handOffToSetUp(SupermuxProjectSetupTarget(
                    projectName: row.project.name,
                    destination: destination,
                    defaultPath: row.location.rootPath,
                    remoteURL: row.remoteURL
                ))
            }
        )
        newWorktreeSheet = SupermuxNewWorktreeSheetItem(model: sheetModel, rowID: row.id, avatar: row.avatar, icon: row.icon)
    }

    // MARK: - Background creates

    /// The rows of this window's creates running in the background under one
    /// sidebar row.
    func pendingRows(for rowID: UUID) -> [SupermuxPendingWorktreeRow] {
        pendingWorktrees.creations(forRow: rowID, owner: pendingWorktreeOwner).map(\.row)
    }

    /// What a background create's row does.
    var pendingActions: SupermuxPendingWorktreeActions {
        SupermuxPendingWorktreeActions(
            cancel: { pendingWorktrees.cancel($0) },
            dismiss: { pendingWorktrees.dismiss($0) },
            reopen: { reopenPendingWorktree($0) }
        )
    }

    /// Shows a failed create's sheet again, with its error and everything
    /// typed, under the project row it ran under.
    private func reopenPendingWorktree(_ id: UUID) {
        guard let creation = pendingWorktrees.reopen(id) else { return }
        if let project = model.projects.first(where: { $0.id == creation.rowID }) {
            newWorktreeSheet = SupermuxNewWorktreeSheetItem(
                model: creation.sheet,
                rowID: project.id,
                avatar: project,
                icon: iconStore.image(for: project.id)
            )
        } else if let row = remote.rows.first(where: { $0.id == creation.rowID }) {
            newWorktreeSheet = SupermuxNewWorktreeSheetItem(
                model: creation.sheet,
                rowID: row.id,
                avatar: row.avatar,
                icon: row.icon
            )
        }
    }

    /// This Mac's target: the projects model and the agent environment, then
    /// the section's own openers (setup script, PR badge hand-off).
    private func localWorktreeTarget(for project: SupermuxProject) -> any SupermuxWorktreeCreationTarget {
        SupermuxLocalWorktreeCreationTarget(
            model: model,
            project: project,
            agentLaunch: agentLaunch,
            onCreated: { worktree, workspaceName, selectsWorkspace in
                openWorktree(
                    worktree,
                    project: project,
                    title: workspaceName,
                    runSetup: true,
                    selectsWorkspace: selectsWorkspace
                )
            },
            onLaunched: { launch in
                // The launcher already noted the project as opened and
                // built the full request (title, command, setup script).
                opener.openWorkspace(launch.openRequest)
            }
        )
    }

    /// Closes the New Worktree sheet, then presents "Set Up on <Mac>…" once
    /// the first sheet is gone (two sheets cannot swap in one transaction).
    private func handOffToSetUp(_ target: SupermuxProjectSetupTarget) {
        newWorktreeSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            projectSetupTarget = target
        }
    }
}

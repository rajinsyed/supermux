import AppKit
import SwiftUI

/// The item that presents ``SupermuxNewWorktreeSheet``.
struct SupermuxNewWorktreeSheetItem: Identifiable {
    let id = UUID()
    let model: SupermuxNewWorktreeSheetModel
    /// The project record the header avatar renders.
    let avatar: SupermuxProject
    let icon: NSImage?
}

/// Presents the one New Worktree sheet from every entry point: a local
/// project row (hover ＋, context menu, "New Worktree on ▸ <Mac>") and a
/// remote-only row. The sheet's device picker lists every Mac with the
/// project; a "Set Up on <Mac>…" row hands off to the setup sheet.
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
        newWorktreeSheet = SupermuxNewWorktreeSheetItem(model: sheetModel, avatar: row.avatar, icon: row.icon)
    }

    /// This Mac's target: the projects model and the agent environment, then
    /// the section's own openers (setup script, PR badge hand-off).
    private func localWorktreeTarget(for project: SupermuxProject) -> any SupermuxWorktreeCreationTarget {
        SupermuxLocalWorktreeCreationTarget(
            model: model,
            project: project,
            agentLaunch: agentLaunch,
            onCreated: { worktree, workspaceName in
                openWorktree(worktree, project: project, title: workspaceName, runSetup: true)
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

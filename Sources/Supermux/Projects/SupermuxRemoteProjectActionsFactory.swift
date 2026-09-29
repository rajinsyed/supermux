import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Builds the Projects section's ``SupermuxRemoteProjectActions`` for one
/// window: each callback runs ``SupermuxRemoteProjectCommands`` against this
/// window's `TabManager` and handles confirmations and error alerts.
@MainActor
enum SupermuxRemoteProjectActionsFactory {
    static func actions(for tabManager: TabManager) -> SupermuxRemoteProjectActions {
        let commands = SupermuxRemoteProjectCommands.shared
        let window = WindowReference(tabManager)
        return SupermuxRemoteProjectActions(
            openProject: { location in
                perform {
                    guard let manager = window.tabManager else { return }
                    _ = try await commands.openProject(location, in: manager)
                }
            },
            openWorktree: { worktree in
                perform {
                    guard let manager = window.tabManager else { return }
                    _ = try await commands.openWorktree(worktree, in: manager)
                }
            },
            removeWorktree: { worktree, deleteBranch in
                perform {
                    do {
                        try await commands.removeWorktree(worktree, deleteBranch: deleteBranch, force: false)
                    } catch where SupermuxRemoteProjectCommands.isDirtyWorktree(error) {
                        guard confirmForceRemoval(worktree) else { return }
                        try await commands.removeWorktree(worktree, deleteBranch: deleteBranch, force: true)
                    }
                }
            },
            runAction: { location, action in
                perform {
                    if let url = try await commands.runAction(location, actionID: action.id) {
                        _ = NSWorkspace.shared.open(url)
                    }
                }
            },
            removeProject: { location, name in
                guard confirmProjectRemoval(name: name, deviceName: location.device?.name ?? "") else { return }
                perform { try await commands.removeProject(location) }
            },
            loadWorktrees: { location in
                guard let raw = location.machineID else { return }
                SupermuxComposition.remoteProjects.ensureWorktrees(
                    on: SurfaceMachineID(rawValue: raw),
                    projectID: location.projectID
                )
            },
            makeWorktreeTarget: { location in
                guard let manager = window.tabManager else { return nil }
                return SupermuxRemoteWorktreeCreationTarget(location: location, tabManager: manager, commands: commands)
            },
            addExistingFolder: { destination, path in
                try await commands.addExistingFolder(destination, path: path)
            },
            cloneRepository: { destination, remoteURL, path in
                try await commands.cloneRepository(destination, remoteURL: remoteURL, path: path)
            }
        )
    }

    /// A weak handle on the window, so a closed window's sidebar actions
    /// never keep its `TabManager` alive.
    @MainActor
    private final class WindowReference {
        weak var tabManager: TabManager?
        init(_ tabManager: TabManager) { self.tabManager = tabManager }
    }

    // MARK: - UI helpers

    private static func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                presentError(error)
            }
        }
    }

    private static func presentError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "supermux.common.errorTitle", defaultValue: "Supermux")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func confirmForceRemoval(_ worktree: SupermuxRemoteWorktree) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.worktree.dirtyDelete.title",
            defaultValue: "Worktree has uncommitted changes"
        )
        alert.informativeText = String(
            localized: "supermux.worktree.dirtyDelete.message",
            defaultValue: "“\(worktree.displayName)” has uncommitted changes that will be lost. Delete anyway?"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "supermux.worktree.dirtyDelete.confirm", defaultValue: "Delete Anyway"))
        alert.addButton(withTitle: String(localized: "supermux.common.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirmProjectRemoval(name: String, deviceName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.remoteProject.removeConfirm.title",
            defaultValue: "Remove “\(name)” from Projects on \(deviceName)?"
        )
        alert.informativeText = String(
            localized: "supermux.remoteProject.removeConfirm.message",
            defaultValue: "The folder, its worktrees and open workspaces stay on that Mac."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "supermux.remoteProject.removeConfirm.confirm", defaultValue: "Remove"))
        alert.addButton(withTitle: String(localized: "supermux.common.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

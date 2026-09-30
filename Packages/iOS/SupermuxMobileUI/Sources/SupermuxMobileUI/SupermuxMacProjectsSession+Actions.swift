import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The closure seams bound to ONE Mac: a project detail screen, its editor
/// sheets and its run controls act through these, so every RPC they send goes
/// to the Mac that owns the project — never simply the foreground Mac. The
/// closures resolve the session's stores at CALL time (weak self), so a sheet
/// outliving a reconnect reaches the fresh stores, or gets
/// `SupermuxMacUnavailableError` once the Mac is gone.
extension SupermuxMacProjectsSession {
    /// Project/preset CRUD on this Mac (plain project ids).
    var editingActions: SupermuxProjectEditingActions {
        SupermuxProjectEditingActions(
            createProject: { [weak self] rootPath in
                try await Self.requireStore(self).createProject(rootPath: rootPath)
            },
            updateProject: { [weak self] projectID, patch in
                try await Self.requireStore(self).updateProject(projectID: projectID, patch: patch)
            },
            deleteProject: { [weak self] projectID in
                try await Self.requireStore(self).deleteProject(projectID: projectID)
            },
            editorProject: { [weak self] projectID in
                self?.store?.projects.first { $0.id == projectID }
            },
            createPreset: { [weak self] request in
                try await Self.requireStore(self).createPreset(request)
            },
            updatePreset: { [weak self] presetID, patch in
                try await Self.requireStore(self).updatePreset(presetID: presetID, patch: patch)
            },
            deletePreset: { [weak self] presetID in
                try await Self.requireStore(self).deletePreset(presetID: presetID)
            },
            rootPathPicker: rootPathPicking
        )
    }

    /// The editor's folder picker over this Mac's registered projects, or
    /// `nil` without `supermux.files.v1`.
    var rootPathPicking: SupermuxProjectRootPathPicking? {
        guard let capabilities, capabilities.supportsFiles else { return nil }
        return SupermuxProjectRootPathPicking(
            rootOptions: { [weak self] in
                (self?.store?.projects ?? []).map { project in
                    SupermuxFolderPickerRootOption(
                        projectID: project.id,
                        name: project.name,
                        rootPath: project.rootPath
                    )
                }
            },
            makeBrowserStore: { [weak self] projectID in
                self?.makeFileBrowserStore(root: .project(id: projectID))
            }
        )
    }

    /// Run/launch/action calls on this Mac, or `nil` while it has no run store.
    var runActions: SupermuxProjectRunActions? {
        guard runStore != nil else { return nil }
        return SupermuxProjectRunActions(
            startRun: { [weak self] projectID, commandID in
                try await Self.requireRunStore(self).startRun(projectID: projectID, commandID: commandID)
            },
            stopRun: { [weak self] projectID in
                try await Self.requireRunStore(self).stopRun(projectID: projectID)
            },
            launchPreset: { [weak self] presetID, projectID in
                try await Self.requireRunStore(self).launchPreset(presetID: presetID, projectID: projectID)
            },
            runAction: { [weak self] projectID, actionID in
                try await Self.requireRunStore(self).runAction(projectID: projectID, actionID: actionID)
            }
        )
    }

    /// A confined file-browser store on this Mac, or `nil` without
    /// `supermux.files.v1`.
    func makeFileBrowserStore(root: SupermuxFilesRoot) -> SupermuxMobileFileBrowserStore? {
        guard let client, let capabilities, capabilities.supportsFiles else { return nil }
        return SupermuxMobileFileBrowserStore(client: client, capabilities: capabilities, root: root)
    }

    /// An agent-launch store for one of this Mac's projects, or `nil` without
    /// `supermux.agent_launch.v1`.
    func makeAgentLaunchStore(forProjectID projectID: String) -> SupermuxMobileAgentLaunchStore? {
        guard let client, let capabilities, capabilities.supportsAgentLaunch else { return nil }
        return SupermuxMobileAgentLaunchStore(client: client, capabilities: capabilities, projectID: projectID)
    }

    /// The Mac-local id of the workspace hosting a project's active run.
    func runningWorkspaceID(forProjectID projectID: String) -> String? {
        guard let runStore, runStore.showsRun,
              let row = runStore.run(forProjectID: projectID),
              row.isRunning == true else {
            return nil
        }
        return row.workspaceId
    }

    /// A project row's run state, or `nil` when the run UI is hidden.
    func runState(for project: SupermuxProjectDTO) -> SupermuxProjectRunState? {
        guard let runStore, runStore.showsRun else { return nil }
        let hasRunCommand = (project.runCommands ?? []).contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasRunCommand else { return nil }
        let row = runStore.run(forProjectID: project.id)
        let isRunning = row?.isRunning == true
        return SupermuxProjectRunState(isRunning: isRunning, command: isRunning ? row?.command : nil)
    }

    static func requireStore(_ session: SupermuxMacProjectsSession?) throws -> SupermuxMobileProjectsStore {
        guard let store = session?.store else { throw SupermuxMacUnavailableError() }
        return store
    }

    static func requireRunStore(_ session: SupermuxMacProjectsSession?) throws -> SupermuxMobileRunStore {
        guard let runStore = session?.runStore else { throw SupermuxMacUnavailableError() }
        return runStore
    }
}

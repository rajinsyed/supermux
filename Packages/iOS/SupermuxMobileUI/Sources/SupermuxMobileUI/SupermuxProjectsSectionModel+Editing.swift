import Foundation
import SupermuxMobileCore
public import SupermuxMobileKit

/// The editing/file-browser seams of ``SupermuxProjectsSectionModel`` — the
/// editor sheets' CRUD closure bundle, the Mac folder-picker seam, and the
/// confined file-browser store factory — split from the main file to respect
/// the per-file length budget (m6-f2). Members are internal (not private)
/// because `actions` in the main file hands them out.
extension SupermuxProjectsSectionModel {
    /// The editor sheets' seam, routing project/preset CRUD through the live
    /// session's store. The closures resolve the store at CALL time (weak
    /// self), so a sheet outliving a reconnect reaches the fresh session —
    /// or, with no session, gets `SupermuxMacUnavailableError` to display.
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

    /// The project editor's Mac folder-picker seam: browsable roots are the
    /// registered projects (`project_id`-rooted `files.*` browsing — the wire
    /// confines every request to an existing root, so arbitrary Mac paths
    /// still go through the editor's text field). `nil` without a live
    /// session or `supermux.files.v1` (the Browse affordance hides). The
    /// closures resolve at CALL time (weak self), so a sheet outliving a
    /// reconnect reaches the fresh session.
    var rootPathPicking: SupermuxProjectRootPathPicking? {
        guard let sessionCapabilities, sessionCapabilities.supportsFiles else { return nil }
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

    /// Builds a file-browser store for one confined root against the live
    /// session's client and capability snapshot. `nil` while disconnected or
    /// when the host lacks `supermux.files.v1` (the capability gate — a fork
    /// phone against an upstream Mac shows no file-browser UI).
    /// - Parameter root: The confined root to browse.
    public func makeFileBrowserStore(root: SupermuxFilesRoot) -> SupermuxMobileFileBrowserStore? {
        guard let sessionClient, let sessionCapabilities,
              sessionCapabilities.supportsFiles else {
            return nil
        }
        return SupermuxMobileFileBrowserStore(
            client: sessionClient,
            capabilities: sessionCapabilities,
            root: root
        )
    }

    /// The live session's store, or `SupermuxMacUnavailableError` when the
    /// session ended (e.g. the sheet outlived a disconnect).
    static func requireStore(
        _ model: SupermuxProjectsSectionModel?
    ) throws -> SupermuxMobileProjectsStore {
        guard let store = model?.store else { throw SupermuxMacUnavailableError() }
        return store
    }
}

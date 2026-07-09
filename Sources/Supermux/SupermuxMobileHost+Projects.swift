import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.projects.*` / `mobile.supermux.project.*` handlers: the
/// Mac side of the iOS Projects section, reads and writes. All state flows
/// through ``SupermuxComposition`` (the same projects model every Mac sidebar
/// shares — create runs the model's own `config.json` import, exactly like
/// the desktop add path); the wire payloads and patch semantics are
/// package-tested SupermuxKit types. `supermux.projects.updated` is emitted
/// by ``SupermuxMobileProjectsObserver`` watching the model, so every write
/// path (mobile or desktop) pokes the phone exactly once.
extension TerminalController {
    /// `mobile.supermux.projects.list`: the registered projects, the global
    /// terminal presets (the same set the desktop bar shows above every
    /// workspace), and the sidebar section's collapse state, as
    /// `{projects: [SupermuxProjectDTO], presets: [SupermuxTerminalPresetDTO],
    /// section_collapsed}`.
    func v2SupermuxProjectsList(params: [String: Any]) async -> V2CallResult {
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        let projects = model.projects
        let presets = model.presets
        let isSectionCollapsed = model.isSectionCollapsed
        do {
            // has_custom_icon stats candidate icon paths per project; keep
            // that file I/O off the main actor.
            let payload = try await Task.detached(priority: .userInitiated) {
                try SupermuxMobileProjectsPayloadBuilder().projectsList(
                    projects: projects,
                    presets: presets,
                    isSectionCollapsed: isSectionCollapsed
                )
            }.value
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode projects list", data: nil)
        }
    }

    /// `mobile.supermux.project.create`: registers the folder at `root_path`
    /// as a project through the exact desktop add path —
    /// ``SupermuxProjectsModel/addProject(rootPath:)`` — which imports a
    /// repo-shipped `.supermux/config.json` / `.superset/config.json` (setup,
    /// teardown, run, actions) before returning. Registering an
    /// already-registered folder returns the existing record (same as
    /// desktop). Result: `{project: SupermuxProjectDTO}` with the imported
    /// fields and the `config_path` read-only marker.
    @MainActor
    func v2SupermuxProjectCreate(params: [String: Any]) async -> V2CallResult {
        guard let raw = params["root_path"] as? String else {
            return .err(code: "invalid_params", message: "root_path is required", data: nil)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !trimmed.isEmpty, expanded.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "root_path must be an absolute folder path", data: nil)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .err(code: "invalid_params", message: "root_path is not an existing folder", data: [
                "root_path": expanded,
            ])
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        let project = await model.addProject(rootPath: expanded)
        return await supermuxProjectResult(project)
    }

    /// `mobile.supermux.project.update`: applies `patch` to the project
    /// (RPC-PROJ-02 patch semantics: only present keys applied; arrays like
    /// `run_commands`/`actions` replaced whole; explicit `null` clears a
    /// nullable field; immutable/unknown keys rejected). Fields owned by a
    /// repo-shipped `config.json` are rejected with `invalid_params`, exactly
    /// like the desktop editor renders them read-only. Result:
    /// `{project: SupermuxProjectDTO}`.
    @MainActor
    func v2SupermuxProjectUpdate(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        guard let patchObject = params["patch"] as? [String: Any] else {
            return .err(code: "invalid_params", message: "patch must be an object", data: nil)
        }
        // The read-only marker probes the filesystem; keep it off the main actor.
        let rootPath = project.rootPath
        let isConfigManaged = await Task.detached(priority: .userInitiated) {
            SupermuxMobileProjectConfigMarker.managedRelativePath(projectRoot: rootPath) != nil
        }.value
        let updated: SupermuxProject
        do {
            let patch = try SupermuxMobileProjectPatch(wire: patchObject)
            updated = try patch.applied(to: project, isConfigManaged: isConfigManaged)
        } catch let error as SupermuxMobilePatchError {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Malformed patch", data: nil)
        }
        SupermuxComposition.projectsModel.updateProject(updated)
        return await supermuxProjectResult(updated)
    }

    /// `mobile.supermux.project.delete`: unregisters the project through the
    /// same model path as the desktop (worktrees and the repository stay on
    /// disk; durable directory associations pointing at the project are
    /// dropped). The confirmation dialog lives on the phone. Result:
    /// `{removed: true, project_id}`.
    @MainActor
    func v2SupermuxProjectDelete(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        SupermuxComposition.projectsModel.removeProject(id: project.id)
        return .ok([
            "removed": true,
            "project_id": project.id.uuidString,
        ])
    }

    /// `mobile.supermux.projects.set_section_collapsed`: persists the sidebar
    /// Projects section's collapse state (the write path for the
    /// `section_collapsed` field `projects.list` returns; the model's own
    /// `didSet` persist is the single shared mutation path with the desktop
    /// header). Result: `{section_collapsed}`.
    @MainActor
    func v2SupermuxProjectsSetSectionCollapsed(params: [String: Any]) async -> V2CallResult {
        guard let collapsed = params["collapsed"] as? Bool else {
            return .err(code: "invalid_params", message: "collapsed must be a boolean", data: nil)
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        model.isSectionCollapsed = collapsed
        return .ok(["section_collapsed": collapsed])
    }

    /// The `{project: SupermuxProjectDTO}` result for one record, built off
    /// the main actor (icon and config probes are file I/O).
    private func supermuxProjectResult(_ project: SupermuxProject) async -> V2CallResult {
        do {
            let payload = try await Task.detached(priority: .userInitiated) {
                try SupermuxMobileProjectsPayloadBuilder().projectPayload(project: project)
            }.value
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode project", data: nil)
        }
    }

    /// `mobile.supermux.project.open`: opens (or focuses) a workspace at the
    /// project root through the same ``SupermuxTabManagerOpener`` path the
    /// desktop uses — which records the workspace→project association via
    /// ``SupermuxWorkspaceAssociationStore`` so the workspace nests under the
    /// project in the Mac sidebar. Result: `{workspace_id, project_id}`.
    @MainActor
    func v2SupermuxProjectOpen(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        SupermuxComposition.projectsModel.noteOpened(id: project.id)
        guard let workspaceID = SupermuxTabManagerOpener(tabManager: tabManager)
            .openWorkspaceReturningWorkspaceId(SupermuxOpenWorkspaceRequest(
                title: project.name,
                directory: project.rootPath,
                colorHex: project.colorHex,
                projectId: project.id
            )) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        return .ok([
            "workspace_id": workspaceID.uuidString,
            "project_id": project.id.uuidString,
        ])
    }

    /// `mobile.supermux.project.icon`: the project's icon as etag'd base64
    /// PNG. With a matching `etag` param the result is
    /// `{not_modified: true, etag}` and carries no image data.
    func v2SupermuxProjectIcon(params: [String: Any]) async -> V2CallResult {
        guard let idString = params["project_id"] as? String,
              let projectID = UUID(uuidString: idString) else {
            return .err(code: "invalid_params", message: "project_id must be a project UUID", data: nil)
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        guard let project = model.projects.first(where: { $0.id == projectID }) else {
            return .err(code: "not_found", message: "Unknown project", data: [
                "project_id": idString
            ])
        }
        let requestedETag = params["etag"] as? String
        let rootPath = project.rootPath
        let customIconPath = project.customIconPath
        // File probing, hashing, and PNG re-encoding run off the main actor.
        let outcome = await Task.detached(priority: .userInitiated) {
            SupermuxProjectIconPayloadBuilder().payload(
                rootPath: rootPath,
                customIconPath: customIconPath,
                ifNoneMatch: requestedETag
            )
        }.value
        switch outcome {
        case .notFound:
            return .err(code: "not_found", message: "Project has no icon image", data: [
                "project_id": idString
            ])
        case let .notModified(etag):
            return .ok([
                "not_modified": true,
                "etag": etag,
            ])
        case let .icon(pngBase64, etag):
            return .ok([
                "not_modified": false,
                "etag": etag,
                "png_base64": pngBase64,
            ])
        }
    }
}

import AppKit
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.preset.*` and `mobile.supermux.action.run` handlers: the
/// Mac side of the iOS terminal-presets editor/launcher and project-actions
/// menu. All preset mutations flow through ``SupermuxProjectsModel``'s
/// presets extension (the same persistence chain the desktop presets bar
/// uses), the wire parsing/patch semantics are the package-tested
/// ``SupermuxMobilePresetPatch``, and launches reuse the desktop paths
/// verbatim (``SupermuxCommandLaunch`` shell input; project actions through
/// ``SupermuxTabManagerOpener/runAction(_:)``).
///
/// `supermux.projects.updated` (presets persist in the projects file) is
/// emitted by ``SupermuxMobileProjectsObserver`` watching the model, so
/// mobile and desktop preset edits poke the phone through one path.
extension TerminalController {
    /// `mobile.supermux.preset.create`: appends a new launchable preset from
    /// flat params `{name, command, icon_symbol?, color_hex?}` (the Mac
    /// assigns the identity). Result: `{preset: SupermuxTerminalPresetDTO}`.
    @MainActor
    func v2SupermuxPresetCreate(params: [String: Any]) async -> V2CallResult {
        let preset: SupermuxTerminalPreset
        do {
            preset = try SupermuxMobilePresetPatch.createPreset(fromWire: params)
        } catch let error as SupermuxMobilePatchError {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Malformed preset params", data: nil)
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        model.addPreset(preset)
        return supermuxPresetResult(preset)
    }

    /// `mobile.supermux.preset.update`: applies `patch` to the preset named
    /// by `preset_id` (patch semantics: only present keys applied; explicit
    /// `null` clears `icon_symbol`/`color_hex`; immutable/unknown keys
    /// rejected). Result: `{preset: SupermuxTerminalPresetDTO}`.
    @MainActor
    func v2SupermuxPresetUpdate(params: [String: Any]) async -> V2CallResult {
        let preset: SupermuxTerminalPreset
        switch await supermuxResolvePreset(params: params) {
        case let .failure(error): return error
        case let .success(resolved): preset = resolved
        }
        guard let patchObject = params["patch"] as? [String: Any] else {
            return .err(code: "invalid_params", message: "patch must be an object", data: nil)
        }
        let updated: SupermuxTerminalPreset
        do {
            let patch = try SupermuxMobilePresetPatch(wire: patchObject)
            updated = patch.applied(to: preset)
        } catch let error as SupermuxMobilePatchError {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Malformed patch", data: nil)
        }
        SupermuxComposition.projectsModel.updatePreset(updated)
        return supermuxPresetResult(updated)
    }

    /// `mobile.supermux.preset.delete`: removes the preset from the bar. The
    /// confirmation dialog lives on the phone. Result:
    /// `{removed: true, preset_id}`.
    @MainActor
    func v2SupermuxPresetDelete(params: [String: Any]) async -> V2CallResult {
        let preset: SupermuxTerminalPreset
        switch await supermuxResolvePreset(params: params) {
        case let .failure(error): return error
        case let .success(resolved): preset = resolved
        }
        SupermuxComposition.projectsModel.removePreset(id: preset.id)
        return .ok([
            "removed": true,
            "preset_id": preset.id.uuidString,
        ])
    }

    /// `mobile.supermux.preset.launch` `{preset_id, project_id?|workspace_id?}`:
    /// runs the preset's command in a fresh terminal tab, exactly like
    /// clicking it in the desktop presets bar — through the workspace's
    /// interactive shell (``SupermuxCommandLaunch``), focused, at the
    /// workspace's directory. With `workspace_id` the preset runs in that
    /// workspace; with `project_id` it runs in a workspace opened (or
    /// focused) at the project root, the same ``SupermuxTabManagerOpener``
    /// path as `project.open`. Result: `{workspace_id, terminal_id}`.
    @MainActor
    func v2SupermuxPresetLaunch(params: [String: Any]) async -> V2CallResult {
        let preset: SupermuxTerminalPreset
        switch await supermuxResolvePreset(params: params) {
        case let .failure(error): return error
        case let .success(resolved): preset = resolved
        }
        guard preset.isLaunchable else {
            return .err(code: "unavailable", message: "Preset has no command", data: [
                "preset_id": preset.id.uuidString,
            ])
        }
        let workspace: Workspace
        switch await supermuxResolveLaunchWorkspace(params: params) {
        case let .failure(error): return error
        case let .success(resolved): workspace = resolved
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first,
            let panel = workspace.newTerminalSurface(
                inPane: paneId,
                // Remote launch: preserve the Mac user's keyboard focus rather
                // than yanking it to the new preset terminal (socket policy).
                focus: false,
                workingDirectory: workspace.currentDirectory,
                initialInput: SupermuxCommandLaunch.shellInput(for: preset.command)
            ) else {
            return .err(code: "unavailable", message: "Failed to open a preset terminal", data: nil)
        }
        return .ok([
            "workspace_id": workspace.id.uuidString,
            "terminal_id": panel.id.uuidString,
        ])
    }

    /// `mobile.supermux.action.run` `{project_id, action_id}`: runs one of
    /// the project's custom actions. An `open_url` action (a command that IS
    /// a single absolute http(s) URL) returns `{kind: "open_url", url}`
    /// WITHOUT executing anything mac-side — the phone opens it locally.
    /// Every other launchable action (editor commands included) executes
    /// through the exact desktop path — a focused terminal tab in the
    /// selected workspace (``SupermuxTabManagerOpener/runAction(_:)``) — and
    /// returns `{ok: true, kind: "command"}`.
    @MainActor
    func v2SupermuxActionRun(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        guard let idString = params["action_id"] as? String,
              let actionID = UUID(uuidString: idString) else {
            return .err(code: "invalid_params", message: "action_id must be an action UUID", data: nil)
        }
        guard let action = project.actions.first(where: { $0.id == actionID }) else {
            return .err(code: "not_found", message: "Unknown action", data: [
                "action_id": idString,
            ])
        }
        switch SupermuxMobileActionRun.outcome(for: action) {
        case nil:
            return .err(code: "unavailable", message: "Action has no command", data: [
                "action_id": idString,
            ])
        case let .openURL(url):
            return .ok(SupermuxMobileActionRun.openURLResult(url: url))
        case .command:
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
            }
            SupermuxComposition.projectsModel.noteOpened(id: project.id)
            // Mirror the desktop's launchAction exactly (title, directory,
            // color, command, association).
            SupermuxTabManagerOpener(tabManager: tabManager).runAction(SupermuxOpenWorkspaceRequest(
                title: "\(project.name) · \(action.name)",
                directory: project.rootPath,
                colorHex: project.colorHex,
                initialCommand: action.command,
                projectId: project.id,
                preservesUserFocus: true
            ))
            return .ok(SupermuxMobileActionRun.commandResult())
        }
    }

    // MARK: - Shared pieces

    /// Resolves the workspace a `preset.launch` runs in: exactly one of
    /// `workspace_id` (an open workspace) or `project_id` (a workspace
    /// opened/focused at the project root), or the wire error to return.
    @MainActor
    private func supermuxResolveLaunchWorkspace(
        params: [String: Any]
    ) async -> SupermuxParamResolution<Workspace> {
        let hasProject = (params["project_id"] as? String)?.isEmpty == false
        let hasWorkspace = (params["workspace_id"] as? String)?.isEmpty == false
        guard hasProject != hasWorkspace else {
            return .failure(.err(
                code: "invalid_params",
                message: "Pass exactly one of project_id or workspace_id",
                data: nil
            ))
        }
        if hasWorkspace {
            guard let idString = params["workspace_id"] as? String,
                  let workspaceID = UUID(uuidString: idString) else {
                return .failure(.err(
                    code: "invalid_params",
                    message: "workspace_id must be a workspace UUID",
                    data: nil
                ))
            }
            guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?
                .tabs.first(where: { $0.id == workspaceID }) else {
                return .failure(.err(code: "not_found", message: "Unknown workspace", data: [
                    "workspace_id": idString,
                ]))
            }
            return .success(workspace)
        }
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): project = resolved
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .failure(.err(code: "unavailable", message: "Workspace context is unavailable", data: nil))
        }
        SupermuxComposition.projectsModel.noteOpened(id: project.id)
        guard let workspaceID = SupermuxTabManagerOpener(tabManager: tabManager)
            .openWorkspaceReturningWorkspaceId(SupermuxOpenWorkspaceRequest(
                title: project.name,
                directory: project.rootPath,
                colorHex: project.colorHex,
                projectId: project.id,
                preservesUserFocus: true
            )),
            let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .failure(.err(code: "unavailable", message: "Workspace context is unavailable", data: nil))
        }
        return .success(workspace)
    }

    /// Resolves the request's `preset_id` against the loaded model, or the
    /// wire error to return (`invalid_params` / `not_found`).
    @MainActor
    private func supermuxResolvePreset(
        params: [String: Any]
    ) async -> SupermuxParamResolution<SupermuxTerminalPreset> {
        guard let idString = params["preset_id"] as? String,
              let presetID = UUID(uuidString: idString) else {
            return .failure(.err(code: "invalid_params", message: "preset_id must be a preset UUID", data: nil))
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        guard let preset = model.presets.first(where: { $0.id == presetID }) else {
            return .failure(.err(code: "not_found", message: "Unknown preset", data: [
                "preset_id": idString,
            ]))
        }
        return .success(preset)
    }

    /// The `{preset: SupermuxTerminalPresetDTO}` result for one record.
    private func supermuxPresetResult(_ preset: SupermuxTerminalPreset) -> V2CallResult {
        do {
            let payload: [String: Any] = [
                "preset": try SupermuxWireJSON().dictionary(from: SupermuxTerminalPresetDTO(preset: preset)),
            ]
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode preset", data: nil)
        }
    }
}

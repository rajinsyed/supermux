#if DEBUG
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// DEBUG-only E2E drivers for the device-aware New Worktree sheet, under
/// `supermux.devices.new_worktree.*`. A session is a real
/// ``SupermuxNewWorktreeSheetModel`` built the way the sidebar builds it
/// (``SupermuxRemoteProjectsPresenter`` → `newWorktreeContext` →
/// `newWorktreeSheetModel`), with the same device rows, default Mac, targets
/// and create flow; only the SwiftUI view is missing.
///
/// Methods (suffix after `supermux.devices.new_worktree.`):
/// `open {project_id, preferred_device?, window_id?}` → session state,
/// `select {session_id, entry_id}`, `load {session_id}`,
/// `submit {session_id, prompt?, workspace_name?, branch_name?, base_branch?, command?, await_open?}`,
/// `state {session_id}`, `close {session_id}`, `last_device {project_id}`,
/// `set_agent_commands {commands, selected?}` (returns the previous list, for restoring).
@MainActor
enum SupermuxNewWorktreeSocketCommands {
    static let methodPrefix = "new_worktree."

    /// The "Set Up on <Mac>…" rows a session handed off (by Mac name).
    @MainActor private final class SetUpLog {
        var names: [String] = []
    }

    @MainActor private final class Session {
        let model: SupermuxNewWorktreeSheetModel
        let setUps: SetUpLog
        init(model: SupermuxNewWorktreeSheetModel, setUps: SetUpLog) {
            self.model = model
            self.setUps = setUps
        }
    }

    private static var sessions: [String: Session] = [:]

    static func handle(
        _ name: String,
        params: [String: Any],
        payloads: SupermuxDevicesSocketPayloads
    ) async throws -> [String: Any] {
        switch name {
        case "open":
            return try open(params)
        case "select":
            let session = try session(params)
            session.model.selectEntry(id: try string(params, "entry_id"))
            return state(session)
        case "load":
            let session = try session(params)
            await session.model.load()
            return state(session)
        case "state":
            return state(try session(params))
        case "submit":
            return try await submit(params, payloads: payloads)
        case "close":
            sessions[try string(params, "session_id")] = nil
            return ["closed": true]
        case "last_device":
            let projectID = try uuid(params, "project_id")
            return ["device_key": SupermuxWorktreeLastDeviceStore().deviceKey(forProject: projectID) ?? NSNull()]
        case "set_agent_commands":
            return setAgentCommands(params)
        default:
            throw invalid("unknown method new_worktree.\(name)")
        }
    }

    // MARK: - Methods

    /// Builds the sheet model for a project exactly as its sidebar row does.
    private static func open(_ params: [String: Any]) throws -> [String: Any] {
        let projectID = try uuid(params, "project_id")
        let tabManager = try SupermuxProjectsSocketCommands.tabManager(params)
        SupermuxComposition.unifiedProjects.recompute()
        let presentation = SupermuxRemoteProjectsPresenter.presentation(for: tabManager)
        let projectsModel = SupermuxComposition.projectsModel
        let sessionID = UUID().uuidString
        let setUps = SetUpLog()
        let onSetUp: @MainActor @Sendable (SupermuxProjectSetupDestination) -> Void = { destination in
            setUps.names.append(destination.name)
        }
        let model: SupermuxNewWorktreeSheetModel
        if let project = projectsModel.projects.first(where: { $0.id == projectID }) {
            model = presentation.newWorktreeSheetModel(
                context: presentation.newWorktreeContext(forLocal: project),
                preferredDeviceKey: params["preferred_device"] as? String,
                localTarget: { localTarget(for: project, in: tabManager) },
                onSetUp: onSetUp
            )
        } else if let row = presentation.rows.first(where: { $0.id == projectID }) {
            model = presentation.newWorktreeSheetModel(
                context: presentation.newWorktreeContext(forRemote: row),
                preferredDeviceKey: params["preferred_device"] as? String,
                localTarget: { nil },
                onSetUp: onSetUp
            )
        } else {
            throw invalid("project_id names no local project or remote-only project row")
        }
        let session = Session(model: model, setUps: setUps)
        sessions[sessionID] = session
        var payload = state(session)
        payload["session_id"] = sessionID
        payload["unified_project_id"] = model.projectID.uuidString
        return payload
    }

    /// Fills the fields, presses Create / Start Claude, waits for the flow,
    /// and (for another Mac) for the mirror the flow opens.
    private static func submit(_ params: [String: Any], payloads: SupermuxDevicesSocketPayloads) async throws -> [String: Any] {
        let session = try session(params)
        let model = session.model
        if let prompt = params["prompt"] as? String { model.prompt = prompt }
        if let name = params["workspace_name"] as? String { model.workspaceName = name }
        if let branch = params["branch_name"] as? String { model.branchInput = branch }
        if let base = params["base_branch"] as? String {
            model.baseBranch = base
            model.baseBranchWasEdited = true
        }
        if let command = params["command"] as? String { model.selectCommand(command) }
        var finished = false
        guard let task = model.submit(onFinished: { finished = true }) else {
            throw invalid("Create is disabled for the selected Mac (can_create is false)")
        }
        await task.value
        var payload = state(session)
        payload["finished"] = finished
        guard finished, let remote = model.target as? SupermuxRemoteWorktreeCreationTarget else { return payload }
        payload["machine"] = remote.machine.rawValue
        payload["remote_workspace_id"] = remote.lastCreatedRef?.workspaceID ?? NSNull()
        if params["await_open"] as? Bool ?? true, let open = remote.lastOpen {
            payload["mirror"] = payloads.opened(try await open.value)
        }
        return payload
    }

    /// Sets this Mac's Claude command list (the loopback device serves the
    /// same list), returning the previous one so a test can restore it.
    private static func setAgentCommands(_ params: [String: Any]) -> [String: Any] {
        let settings = SupermuxComposition.agentLaunch.settings
        let previous = settings.commands
        let previousSelected = settings.selectedCommand
        if let commands = params["commands"] as? [String] { settings.setCommands(commands) }
        if let selected = params["selected"] as? String { settings.setSelectedCommand(selected) }
        return [
            "previous": previous,
            "previous_selected": previousSelected,
            "commands": settings.commands,
            "selected": settings.selectedCommand,
        ]
    }

    // MARK: - Pieces

    /// This Mac's target, opening a created worktree in the given window.
    private static func localTarget(for project: SupermuxProject, in tabManager: TabManager) -> any SupermuxWorktreeCreationTarget {
        let opener = SupermuxTabManagerOpener(tabManager: tabManager)
        return SupermuxLocalWorktreeCreationTarget(
            model: SupermuxComposition.projectsModel,
            project: project,
            agentLaunch: SupermuxComposition.agentLaunch,
            onCreated: { worktree, name in
                opener.openWorkspace(SupermuxOpenWorkspaceRequest(
                    title: name ?? worktree.displayName,
                    directory: worktree.path,
                    colorHex: project.colorHex,
                    projectId: project.id
                ))
            },
            onLaunched: { launch in opener.openWorkspace(launch.openRequest) }
        )
    }

    private static func state(_ session: Session) -> [String: Any] {
        let model = session.model
        let target: Any = model.target.map { target -> [String: Any] in
            [
                "project_id": target.projectID.uuidString,
                "remote_device_name": target.remoteDeviceName ?? NSNull(),
                "supports_agent_launch": target.supportsAgentLaunch,
            ]
        } ?? NSNull()
        return [
            "selected_entry_id": model.selectedEntryID ?? NSNull(),
            "shows_picker": model.showsDevicePicker,
            "entries": model.entries.map(entry),
            "target": target,
            "branches": model.localBranches,
            "branches_loaded": model.branchesLoaded,
            "base_branch": model.baseBranch,
            "branch_load_error": model.branchLoadError ?? NSNull(),
            "commands": model.commands,
            "command": model.command,
            "models_error": model.modelsError ?? NSNull(),
            "ai_naming_configured": model.aiNamingConfigured,
            "prompt": model.prompt,
            "workspace_name": model.workspaceName,
            "branch_name": model.branchInput,
            "phase": "\(model.phase)",
            "status_message": model.statusMessage ?? NSNull(),
            "error_message": model.errorMessage ?? NSNull(),
            "can_create": model.canCreate,
            "shows_prompt_editor": model.showsPromptEditor,
            "preview_line": model.previewLine ?? NSNull(),
            "set_up_requests": session.setUps.names,
        ]
    }

    private static func entry(_ entry: SupermuxWorktreeDeviceEntry) -> [String: Any] {
        [
            "id": entry.id,
            "device_key": entry.deviceKey,
            "name": entry.name,
            "availability": entry.availability.rawValue,
            "kind": entry.location != nil ? "create" : "set_up",
            "can_create": entry.canCreate,
            "is_this_mac": entry.isThisMac,
            "project_id": entry.location?.projectID.uuidString ?? NSNull(),
        ]
    }

    // MARK: - Params

    private static func session(_ params: [String: Any]) throws -> Session {
        guard let session = sessions[try string(params, "session_id")] else {
            throw invalid("session_id names no open new_worktree session")
        }
        return session
    }

    private static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else { throw invalid("\(key) is required") }
        return value
    }

    private static func uuid(_ params: [String: Any], _ key: String) throws -> UUID {
        guard let raw = params[key] as? String, let id = UUID(uuidString: raw) else {
            throw invalid("\(key) must be a UUID")
        }
        return id
    }

    private static func invalid(_ message: String) -> SupermuxDeviceError {
        .hostRejected(code: "invalid_params", message: message)
    }
}
#endif

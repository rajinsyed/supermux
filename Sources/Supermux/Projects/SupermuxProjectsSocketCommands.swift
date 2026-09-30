import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Projects-across-Macs methods under the `supermux.devices.*` socket prefix
/// (dispatched from ``SupermuxDevicesSocketCommands``'s fallback, so no new
/// upstream touchpoint). They drive the same code paths as the sidebar, so an
/// E2E script can check nesting and remote actions without clicking.
///
/// Methods (suffix after `supermux.devices.`):
/// `unified_projects {window_id?}`, `remote_projects {refresh?}`,
/// `remote_worktrees {machine, project_id}`,
/// `remote_worktree_create {machine, project_id, workspace_name?, branch_name?, base_branch?, focus?, window_id?}`,
/// `remote_action_run {machine, project_id, action_id, window_id?}` (the row's Actions menu),
/// `project_sync {}`, `projects_presentation {window_id?}`.
@MainActor
enum SupermuxProjectsSocketCommands {
    private static let methods: Set<String> = [
        "unified_projects", "remote_projects", "remote_worktrees",
        "remote_worktree_create", "remote_action_run", "project_sync", "projects_presentation",
    ]

    /// Whether `name` (the part after `supermux.devices.`) is served here.
    static func handles(_ name: String) -> Bool {
        methods.contains(name)
    }

    /// Runs one method. Throws ``SupermuxDeviceError`` (`invalid_params` via
    /// `.hostRejected`) on bad input.
    static func handle(_ name: String, params: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "unified_projects":
            let unified = SupermuxComposition.unifiedProjects
            unified.recompute()
            return [
                "projects": unified.list.projects.map(SupermuxProjectsSocketPayloads.unifiedProject),
                "mirror_owners": Dictionary(uniqueKeysWithValues: unified.mirrorOwners.map {
                    ($0.key.uuidString, $0.value.uuidString)
                }),
                "nesting": SupermuxProjectsSocketPayloads.nesting(for: try tabManager(params)),
            ]
        case "remote_projects":
            let remote = SupermuxComposition.remoteProjects
            if params["refresh"] as? Bool == true {
                for device in remote.devices where device.isOnline { await remote.refresh(device.machine) }
            }
            return ["devices": remote.devices.map { device in
                SupermuxProjectsSocketPayloads.device(
                    device,
                    icons: remote.icons.keys.filter { $0.hasPrefix(device.machine.rawValue + "|") }.count
                )
            }]
        case "remote_worktrees":
            let machine = try machine(params)
            let projectID = try uuid(params, "project_id")
            let remote = SupermuxComposition.remoteProjects
            await remote.refreshWorktrees(on: machine, projectID: projectID)
            let list = remote.device(machine)?.worktreesByProjectID[projectID] ?? []
            return ["worktrees": list.map(SupermuxProjectsSocketPayloads.worktree)]
        case "remote_worktree_create":
            return try await remoteWorktreeCreate(params)
        case "remote_action_run":
            return try await remoteActionRun(params)
        case "project_sync":
            let report = await SupermuxComposition.projectSync.syncNow()
            return SupermuxProjectsSocketPayloads.syncReport(report)
        case "projects_presentation":
            return SupermuxProjectsSocketPayloads.presentation(for: try tabManager(params))
        default:
            throw invalid("unknown method \(name)")
        }
    }

    /// The sidebar's remote New Worktree path: `worktree.create {open:true}`
    /// on the device, then the mirror opens here.
    private static func remoteWorktreeCreate(_ params: [String: Any]) async throws -> [String: Any] {
        let (location, _) = try remoteProject(params)
        let request = SupermuxRemoteWorktreeRequest(
            workspaceName: params["workspace_name"] as? String ?? "",
            branchName: params["branch_name"] as? String ?? "",
            baseBranch: params["base_branch"] as? String ?? ""
        )
        let manager = try tabManager(params)
        let opened = try await SupermuxRemoteProjectCommands.shared.createWorktree(
            location,
            request: request,
            in: manager,
            focus: params["focus"] as? Bool ?? false
        )
        SupermuxComposition.unifiedProjects.recompute()
        return [
            "workspace_id": opened.workspace.id.uuidString,
            "title": opened.workspace.title,
            "machine": opened.ref.machineID,
            "remote_workspace_id": opened.ref.workspaceID,
            "reused": opened.reused,
            "owner_project_id": SupermuxComposition.unifiedProjects.mirrorOwners[opened.workspace.id]?.uuidString ?? NSNull(),
        ]
    }

    /// A remote project row's Actions menu item.
    private static func remoteActionRun(_ params: [String: Any]) async throws -> [String: Any] {
        let (location, project) = try remoteProject(params)
        let actionID = try uuid(params, "action_id")
        guard let action = project?.actions?.first(where: { UUID(uuidString: $0.id) == actionID }) else {
            throw invalid("action_id does not name an action of that project")
        }
        let url = try await SupermuxRemoteProjectCommands.shared.runAction(location, action: action, in: try tabManager(params))
        return ["outcome": url == nil ? "command" : "open_url", "url": url?.absoluteString ?? NSNull()]
    }

    /// The device project named by `machine` + `project_id`, as a row's location.
    private static func remoteProject(_ params: [String: Any]) throws -> (SupermuxProjectLocation, SupermuxProjectDTO?) {
        let machine = try machine(params)
        let projectID = try uuid(params, "project_id")
        guard let device = SupermuxComposition.remoteProjects.device(machine) else {
            throw SupermuxDeviceError.unknownDevice(machine.rawValue)
        }
        let project = device.project(id: projectID)
        let location = SupermuxProjectLocation(
            place: .device(device.device),
            projectID: projectID,
            rootPath: project?.rootPath ?? ""
        )
        return (location, project)
    }

    // MARK: - Params

    private static func invalid(_ message: String) -> SupermuxDeviceError {
        .hostRejected(code: "invalid_params", message: message)
    }

    private static func machine(_ params: [String: Any]) throws -> SurfaceMachineID {
        guard let raw = params["machine"] as? String, SurfaceMachineID(rawValue: raw).isDevice else {
            throw invalid("machine must be a device id (device:<uuid>@<tag>) from supermux.devices.list")
        }
        return SurfaceMachineID(rawValue: raw)
    }

    private static func uuid(_ params: [String: Any], _ key: String) throws -> UUID {
        guard let raw = params[key] as? String, let id = UUID(uuidString: raw) else {
            throw invalid("\(key) must be a UUID")
        }
        return id
    }

    /// The window named by `window_id`, else the preferred main window.
    static func tabManager(_ params: [String: Any]) throws -> TabManager {
        guard let app = AppDelegate.shared else { throw SupermuxDeviceError.windowUnavailable }
        if let raw = params["window_id"] as? String {
            guard let id = UUID(uuidString: raw), let manager = app.tabManagerFor(windowId: id) else {
                throw invalid("window_id does not name an open window")
            }
            return manager
        }
        guard let manager = app.preferredMainWindowContextForWorkspaceCreation(debugSource: "supermux.projects")?.tabManager else {
            throw SupermuxDeviceError.windowUnavailable
        }
        return manager
    }
}

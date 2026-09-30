import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// The one path for acting on a project copy on another Mac: the RPC to that
/// Mac, then (for anything that opens a workspace there) opening its local
/// mirror in the given window through ``SupermuxDeviceWorkspaceOpener``.
/// Shared by the sidebar actions and the `supermux.devices.*` socket methods,
/// so E2E drives exactly what a click does. No UI here; callers confirm and
/// present errors.
@MainActor
struct SupermuxRemoteProjectCommands {
    let devices: SupermuxDevices
    let opener: SupermuxDeviceWorkspaceOpener
    let remoteProjects: SupermuxRemoteProjectsModel
    let projectsModel: SupermuxProjectsModel
    let setupService: SupermuxProjectSetupService

    /// The composition's instances.
    static var shared: SupermuxRemoteProjectCommands {
        SupermuxRemoteProjectCommands(
            devices: SupermuxComposition.devices,
            opener: SupermuxComposition.deviceWorkspaceOpener,
            remoteProjects: SupermuxComposition.remoteProjects,
            projectsModel: SupermuxComposition.projectsModel,
            setupService: SupermuxComposition.projectSetupService
        )
    }

    /// `git clone` on the other Mac can take long; its host deadline is
    /// ``SupermuxProjectSetupService/cloneTimeout``.
    static let cloneTimeout: Duration = .seconds(Int(SupermuxProjectSetupService.cloneTimeout) + 60)

    // MARK: - Workspaces on the other Mac

    /// `project.open` there, then open and focus its mirror here.
    func openProject(
        _ location: SupermuxProjectLocation,
        in tabManager: TabManager
    ) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let machine = try Self.machine(of: location)
        let result = try await devices.request(
            .projectOpen,
            params: ["project_id": location.projectID.uuidString],
            on: machine
        )
        return try await openReturnedWorkspace(result, on: machine, in: tabManager)
    }

    /// `worktree.open` there, then open and focus its mirror here.
    func openWorktree(
        _ worktree: SupermuxRemoteWorktree,
        in tabManager: TabManager
    ) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let machine = try Self.machine(of: worktree.location)
        let result = try await devices.request(
            .worktreeOpen,
            params: ["project_id": worktree.location.projectID.uuidString, "worktree_path": worktree.path],
            on: machine
        )
        return try await openReturnedWorkspace(result, on: machine, in: tabManager)
    }

    /// `worktree.create {open: true}` there (long deadline), then open and
    /// select its mirror here. Returns the other Mac's workspace id too.
    func createWorktree(
        _ location: SupermuxProjectLocation,
        request: SupermuxRemoteWorktreeRequest,
        in tabManager: TabManager,
        focus: Bool = true
    ) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let ref = try await requestWorktreeCreate(location, request: request)
        return try await opener.openWhenAvailable(ref, in: tabManager, focus: focus)
    }

    /// `agent.start` there (long deadline), then open and select its mirror
    /// here: the prompt-first sibling of ``createWorktree(_:request:in:focus:)``.
    func startAgent(
        _ location: SupermuxProjectLocation,
        request: SupermuxAgentLaunchRequest,
        in tabManager: TabManager,
        focus: Bool = true
    ) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let ref = try await requestAgentStart(location, request: request)
        return try await opener.openWhenAvailable(ref, in: tabManager, focus: focus)
    }

    /// The RPC half of ``createWorktree(_:request:in:focus:)``: the workspace
    /// the other Mac opened in the new worktree.
    func requestWorktreeCreate(
        _ location: SupermuxProjectLocation,
        request: SupermuxRemoteWorktreeRequest
    ) async throws -> SupermuxRemoteWorkspaceRef {
        let machine = try Self.machine(of: location)
        var params: [String: Any] = ["project_id": location.projectID.uuidString, "open": true]
        if let name = Self.nonEmpty(request.workspaceName) { params["workspace_name"] = name }
        if let branch = Self.nonEmpty(request.branchName) { params["branch_name"] = branch }
        if let base = Self.nonEmpty(request.baseBranch) { params["base_branch"] = base }
        let result = try await devices.request(
            .worktreeCreate,
            params: params,
            on: machine,
            timeout: SupermuxDevices.longOperationTimeout
        )
        Task { await remoteProjects.refreshWorktrees(on: machine, projectID: location.projectID) }
        return try Self.workspaceRef(in: result, on: machine)
    }

    /// The RPC half of ``startAgent(_:request:in:focus:)``: `agent.start`
    /// with `request` (whose `projectId` is that Mac's id) and the workspace
    /// it opened there. A blank command lets that Mac use its selected one.
    func requestAgentStart(
        _ location: SupermuxProjectLocation,
        request: SupermuxAgentLaunchRequest
    ) async throws -> SupermuxRemoteWorkspaceRef {
        let machine = try Self.machine(of: location)
        var params: [String: Any] = ["project_id": location.projectID.uuidString, "prompt": request.prompt]
        let optional: [(String, String?)] = [
            ("command", request.command), ("model", request.model), ("effort", request.effort),
            ("base_branch", request.baseBranch), ("workspace_name", request.workspaceName),
            ("branch_name", request.branchName),
        ]
        for (key, value) in optional {
            if let value = value.flatMap(Self.nonEmpty) { params[key] = value }
        }
        let result = try await devices.request(
            .agentStart,
            params: params,
            on: machine,
            timeout: SupermuxDevices.longOperationTimeout
        )
        Task { await remoteProjects.refreshWorktrees(on: machine, projectID: location.projectID) }
        return try Self.workspaceRef(in: result, on: machine)
    }

    // MARK: - Other operations

    /// `worktree.remove` there. A dirty worktree without `force` throws the
    /// host's `dirty_worktree` rejection (see ``isDirtyWorktree(_:)``).
    func removeWorktree(_ worktree: SupermuxRemoteWorktree, deleteBranch: Bool, force: Bool) async throws {
        let machine = try Self.machine(of: worktree.location)
        _ = try await devices.request(
            .worktreeRemove,
            params: [
                "project_id": worktree.location.projectID.uuidString,
                "worktree_path": worktree.path,
                "force": force,
                "delete_branch": deleteBranch,
            ],
            on: machine,
            timeout: SupermuxDevices.longOperationTimeout
        )
        await remoteProjects.refreshWorktrees(on: machine, projectID: worktree.location.projectID)
    }

    /// `action.run` there. Returns the URL of an `open_url` action, which the
    /// caller opens on this Mac.
    func runAction(_ location: SupermuxProjectLocation, actionID: String) async throws -> URL? {
        let result = try await devices.request(
            .actionRun,
            params: ["project_id": location.projectID.uuidString, "action_id": actionID],
            on: try Self.machine(of: location)
        )
        guard result["kind"] as? String == "open_url", let raw = result["url"] as? String else { return nil }
        return URL(string: raw)
    }

    /// `project.delete` there (the repository and worktrees stay on disk).
    func removeProject(_ location: SupermuxProjectLocation) async throws {
        let machine = try Self.machine(of: location)
        _ = try await devices.request(.projectDelete, params: ["project_id": location.projectID.uuidString], on: machine)
        await remoteProjects.refresh(machine)
    }

    /// Registers an existing folder as a project on `destination`.
    @discardableResult
    func addExistingFolder(_ destination: SupermuxProjectSetupDestination, path: String) async throws -> String {
        guard let root = SupermuxProjectSetupService.standardizedRoot(path) else {
            throw SupermuxProjectSetupError.invalidPath
        }
        switch destination {
        case .thisMac:
            let probe = await setupService.probe(rootPath: root, isSuppressed: false)
            guard probe.exists, probe.isDirectory else {
                throw SupermuxDeviceError.hostRejected(code: "invalid_params", message: String(
                    localized: "supermux.projectSetup.error.missingFolder",
                    defaultValue: "“\(root)” is not an existing folder."
                ))
            }
            await projectsModel.loadIfNeeded()
            return await projectsModel.addProject(rootPath: root).id.uuidString
        case .device(let device):
            let machine = SurfaceMachineID(rawValue: device.machineID)
            let result = try await devices.request(.projectCreate, params: ["root_path": root], on: machine)
            await remoteProjects.refresh(machine)
            return (result["project"] as? [String: Any])?["id"] as? String ?? ""
        }
    }

    /// Clones `remoteURL` into `path` on `destination` and registers it.
    @discardableResult
    func cloneRepository(
        _ destination: SupermuxProjectSetupDestination,
        remoteURL: String,
        path: String
    ) async throws -> String {
        switch destination {
        case .thisMac:
            let root = try await setupService.clone(remoteURL: remoteURL, into: path)
            await projectsModel.loadIfNeeded()
            return await projectsModel.addProject(rootPath: root).id.uuidString
        case .device(let device):
            let machine = SurfaceMachineID(rawValue: device.machineID)
            let result = try await devices.request(
                .projectClone,
                params: ["remote_url": remoteURL, "root_path": path],
                on: machine,
                timeout: Self.cloneTimeout
            )
            await remoteProjects.refresh(machine)
            return (result["project"] as? [String: Any])?["id"] as? String ?? ""
        }
    }

    /// Whether an error is the host's "worktree has uncommitted changes".
    static func isDirtyWorktree(_ error: any Error) -> Bool {
        (error as? SupermuxDeviceError)?.code == "dirty_worktree"
    }

    // MARK: - Helpers

    private func openReturnedWorkspace(
        _ result: [String: Any],
        on machine: SurfaceMachineID,
        in tabManager: TabManager,
        focus: Bool = true
    ) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let ref = try Self.workspaceRef(in: result, on: machine)
        return try await opener.openWhenAvailable(ref, in: tabManager, focus: focus)
    }

    /// The `workspace_id` a host RPC returned, as a ref on `machine`.
    private static func workspaceRef(in result: [String: Any], on machine: SurfaceMachineID) throws -> SupermuxRemoteWorkspaceRef {
        guard let workspaceID = result["workspace_id"] as? String, !workspaceID.isEmpty else {
            throw SupermuxDeviceError.malformedResponse("workspace_id")
        }
        return SupermuxRemoteWorkspaceRef(machine: machine, workspaceID: workspaceID)
    }

    static func machine(of location: SupermuxProjectLocation) throws -> SurfaceMachineID {
        guard let raw = location.machineID else { throw SupermuxDeviceError.unknownDevice("this Mac") }
        return SurfaceMachineID(rawValue: raw)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

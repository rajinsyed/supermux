import Foundation
import SupermuxKit

/// `run.start` / `run.stop` with the additive `workspace_id` param: another
/// Mac mirroring one of this Mac's workspaces presses ⌘G (or Run) in the
/// mirror, and the run starts or stops in exactly that workspace here — like
/// ⌘G pressed in it locally (one run per workspace, not one per project).
/// Without the param the handlers keep their project-wide behavior; an older
/// host ignores the param and falls back to that behavior.
extension TerminalController {
    /// Starts the project's run command in the named workspace.
    @MainActor
    func supermuxRunStartInNamedWorkspace(
        project: SupermuxProject,
        commandOverride: String?,
        params: [String: Any]
    ) -> V2CallResult {
        let workspace: Workspace
        switch supermuxRunNamedWorkspace(params: params) {
        case let .failure(error): return error
        case let .success(resolved): workspace = resolved
        }
        switch SupermuxComposition.runCoordinator.startRun(workspace: workspace, commandOverride: commandOverride) {
        case .started, .alreadyRunning:
            return supermuxRunWorkspaceResult(projectId: project.id, workspaceId: workspace.id)
        case .missingRunCommand:
            return .err(
                code: "unavailable",
                message: "No run command configured for this project",
                data: ["project_id": project.id.uuidString]
            )
        case .missingProject:
            return .err(
                code: "unavailable",
                message: "The workspace does not belong to a registered project",
                data: ["workspace_id": workspace.id.uuidString]
            )
        case .launchFailed:
            return .err(code: "unavailable", message: "Failed to open a run terminal", data: nil)
        }
    }

    /// Stops the named workspace's run (idempotent when it is not running).
    @MainActor
    func supermuxRunStopInNamedWorkspace(project: SupermuxProject, params: [String: Any]) -> V2CallResult {
        let workspace: Workspace
        switch supermuxRunNamedWorkspace(params: params) {
        case let .failure(error): return error
        case let .success(resolved): workspace = resolved
        }
        switch SupermuxComposition.runCoordinator.stopRun(workspaceId: workspace.id) {
        case .stopped, .notRunning:
            return supermuxRunWorkspaceResult(projectId: project.id, workspaceId: workspace.id)
        case .stopFailed:
            return .err(
                code: "unavailable",
                message: "The run terminal did not accept the interrupt",
                data: ["workspace_id": workspace.id.uuidString]
            )
        }
    }

    /// The named workspace: open here and not itself a device mirror.
    @MainActor
    private func supermuxRunNamedWorkspace(params: [String: Any]) -> SupermuxParamResolution<Workspace> {
        guard let raw = params["workspace_id"] as? String, let id = UUID(uuidString: raw) else {
            return .failure(.err(code: "invalid_params", message: "workspace_id must be a workspace UUID", data: nil))
        }
        guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first(where: { $0.id == id }),
              !SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) else {
            return .failure(.err(code: "not_found", message: "Workspace not found", data: ["workspace_id": raw]))
        }
        return .success(workspace)
    }

    /// `{run}` for the named workspace's own run (the project's idle row when none).
    @MainActor
    private func supermuxRunWorkspaceResult(projectId: UUID, workspaceId: UUID) -> V2CallResult {
        let snapshot = SupermuxComposition.runCoordinator.mobileRunSnapshots.first { $0.workspaceId == workspaceId }
        do {
            return .ok(try SupermuxMobileRunPayloadBuilder().runPayload(projectId: projectId, snapshot: snapshot))
        } catch {
            return .err(code: "unavailable", message: "Failed to encode run state", data: nil)
        }
    }
}

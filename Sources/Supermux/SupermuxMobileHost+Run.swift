import AppKit
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.run.*` handlers: the Mac side of the iOS run
/// (dev-server) controls. All run state lives in
/// ``SupermuxComposition/runCoordinator`` — the exact ⌘G coordinator the
/// desktop uses, never a re-implementation — and the wire payloads are built
/// by the package-tested ``SupermuxMobileRunPayloadBuilder``.
/// `supermux.run.updated` is emitted by ``SupermuxMobileRunObserver``
/// watching the coordinator, so mobile and desktop transitions poke the
/// phone through one path.
extension TerminalController {
    /// `mobile.supermux.run.state`: `{runs: [SupermuxRunStateDTO]}` — one row
    /// per registered project (so the phone can paint run dots on every
    /// project row), folding in the live command/workspace/start time for
    /// running projects.
    @MainActor
    func v2SupermuxRunState(params: [String: Any]) async -> V2CallResult {
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        do {
            let payload = try SupermuxMobileRunPayloadBuilder().runState(
                projects: model.projects,
                snapshots: SupermuxComposition.runCoordinator.mobileRunSnapshots
            )
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode run state", data: nil)
        }
    }

    /// `mobile.supermux.run.start` `{project_id, command_id?}`: starts the
    /// project's run command with desktop ⌘G semantics — no `command_id`
    /// chains every configured run command with `&&`; a `command_id` (the
    /// 0-based index into the project's `run_commands` array as
    /// `projects.list` delivers it) runs that one command. The run launches
    /// in an open workspace of the project, opening one at the project root
    /// first when none exists (the same ``SupermuxTabManagerOpener`` path as
    /// `project.open`). Idempotent: an already-running project returns its
    /// current state. Result: `{run: SupermuxRunStateDTO}`.
    @MainActor
    func v2SupermuxRunStart(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        var commandOverride: String?
        if params["command_id"] != nil {
            guard let index = params["command_id"] as? Int,
                  let selected = SupermuxMobileRunCommand.selected(
                      commands: project.runCommands,
                      index: index
                  ) else {
                return .err(
                    code: "invalid_params",
                    message: "command_id must index a non-empty run command",
                    data: ["run_commands": project.runCommands]
                )
            }
            commandOverride = selected
        }
        let coordinator = SupermuxComposition.runCoordinator
        let builder = SupermuxMobileRunPayloadBuilder()
        // Idempotent: a project already running keeps its current run.
        if builder.representativeSnapshot(
            for: project.id, in: coordinator.mobileRunSnapshots
        ) != nil {
            return supermuxRunResult(projectId: project.id)
        }
        guard let workspace = supermuxRunTargetWorkspace(for: project, params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        switch coordinator.startRun(workspace: workspace, commandOverride: commandOverride) {
        case .started, .alreadyRunning:
            return supermuxRunResult(projectId: project.id)
        case .missingRunCommand:
            return .err(
                code: "unavailable",
                message: "No run command configured for this project",
                data: ["project_id": project.id.uuidString]
            )
        case .missingProject:
            return .err(
                code: "unavailable",
                message: "The workspace no longer matches a registered project",
                data: nil
            )
        case .launchFailed:
            return .err(code: "unavailable", message: "Failed to open a run terminal", data: nil)
        }
    }

    /// `mobile.supermux.run.stop` `{project_id}`: interrupts the project's
    /// running command (Ctrl+C into the run surface, exactly like the desktop
    /// toggle). Idempotent: a project with no live run returns
    /// `is_running: false`. Result: `{run: SupermuxRunStateDTO}`.
    @MainActor
    func v2SupermuxRunStop(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        let coordinator = SupermuxComposition.runCoordinator
        guard let snapshot = SupermuxMobileRunPayloadBuilder().representativeSnapshot(
            for: project.id, in: coordinator.mobileRunSnapshots
        ) else {
            return supermuxRunResult(projectId: project.id)
        }
        switch coordinator.stopRun(workspaceId: snapshot.workspaceId) {
        case .stopped, .notRunning:
            return supermuxRunResult(projectId: project.id)
        case .stopFailed:
            return .err(
                code: "unavailable",
                message: "The run terminal did not accept the interrupt",
                data: ["workspace_id": snapshot.workspaceId.uuidString]
            )
        }
    }

    // MARK: - Shared pieces

    /// The `{run: SupermuxRunStateDTO}` result reflecting the project's
    /// current coordinator state.
    @MainActor
    private func supermuxRunResult(projectId: UUID) -> V2CallResult {
        let builder = SupermuxMobileRunPayloadBuilder()
        do {
            let payload = try builder.runPayload(
                projectId: projectId,
                snapshot: builder.representativeSnapshot(
                    for: projectId,
                    in: SupermuxComposition.runCoordinator.mobileRunSnapshots
                )
            )
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode run state", data: nil)
        }
    }

    /// The workspace a mobile `run.start` launches in: an already-open
    /// workspace whose directory matches the project (each window's selected
    /// workspace preferred, mirroring the desktop ⌘G target), else a
    /// workspace opened (or focused) at the project root through the same
    /// ``SupermuxTabManagerOpener`` path as `project.open`.
    @MainActor
    private func supermuxRunTargetWorkspace(
        for project: SupermuxProject,
        params: [String: Any]
    ) -> Workspace? {
        let matcher = SupermuxProjectMatcher()
        let projects = SupermuxComposition.projectsModel.projects
        for workspace in supermuxOrderedOpenWorkspaces()
        where matcher.project(for: workspace.currentDirectory, in: projects)?.id == project.id {
            return workspace
        }
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        SupermuxComposition.projectsModel.noteOpened(id: project.id)
        guard let workspaceID = SupermuxTabManagerOpener(tabManager: tabManager)
            .openWorkspaceReturningWorkspaceId(SupermuxOpenWorkspaceRequest(
                title: project.name,
                directory: project.rootPath,
                colorHex: project.colorHex,
                projectId: project.id,
                preservesUserFocus: true
            )) else { return nil }
        return tabManager.tabs.first(where: { $0.id == workspaceID })
    }

    /// Every open workspace across all main windows, each window's selected
    /// workspace first (the same window walk as the worktree handlers'
    /// snapshot fold).
    @MainActor
    private func supermuxOrderedOpenWorkspaces() -> [Workspace] {
        guard let app = AppDelegate.shared else { return [] }
        var seenWindowIDs: Set<UUID> = []
        var seenWorkspaceIDs: Set<UUID> = []
        var workspaces: [Workspace] = []
        for summary in app.listMainWindowSummaries() {
            guard seenWindowIDs.insert(summary.windowId).inserted,
                  let windowTabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            let ordered = [windowTabManager.selectedWorkspace].compactMap { $0 }
                + windowTabManager.tabs
            for workspace in ordered where seenWorkspaceIDs.insert(workspace.id).inserted {
                workspaces.append(workspace)
            }
        }
        return workspaces
    }
}

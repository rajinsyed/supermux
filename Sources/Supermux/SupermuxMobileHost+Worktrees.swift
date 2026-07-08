import AppKit
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.worktree(s).*` handlers: the Mac side of the iOS worktree
/// screens. All git work runs through ``SupermuxComposition/projectsModel``
/// (the exact model the desktop sidebar uses — never a re-implementation),
/// the wire payloads are built by package-tested SupermuxKit types, and
/// workspace opening routes through ``SupermuxTabManagerOpener`` so the setup
/// script runs in a dedicated terminal exactly like the desktop flow.
extension TerminalController {
    /// `mobile.supermux.worktrees.list`: the project's worktrees as
    /// `{worktrees: [SupermuxWorktreeDTO]}`, folding open-workspace state and
    /// pull-request badges (per-workspace probe for opened worktrees, the
    /// shared ``SupermuxWorktreePullRequestModel`` for unopened ones).
    @MainActor
    func v2SupermuxWorktreesList(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        let model = SupermuxComposition.projectsModel
        await model.refreshWorktrees(for: project.id)
        let worktrees = model.worktreesByProjectId[project.id] ?? []
        do {
            let payload = try SupermuxMobileWorktreesPayloadBuilder().worktreesList(
                worktrees: worktrees,
                openWorkspaces: supermuxOpenWorkspaceSnapshots(),
                pullRequestsByWorktreePath:
                    SupermuxComposition.worktreePullRequestModel.pullRequestsByWorktreePath
            )
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode worktrees list", data: nil)
        }
    }

    /// `mobile.supermux.worktree.suggest_branch`: `{branch_name, source}` —
    /// AI-named when a key is configured (mac-side only; no key material can
    /// travel), friendly-random otherwise. Never an error.
    @MainActor
    func v2SupermuxWorktreeSuggestBranch(params: [String: Any]) async -> V2CallResult {
        let suggestion = await SupermuxMobileBranchSuggestion.suggest(
            workspaceName: params["workspace_name"] as? String,
            namer: SupermuxComposition.aiBranchNamer
        )
        return .ok(suggestion.wirePayload)
    }

    /// `mobile.supermux.worktree.create`: creates a worktree (blank branch +
    /// workspace name → AI naming when configured, mirroring the desktop
    /// sheet; the service falls back to a random name for blank input) and,
    /// with `open: true`, opens a workspace in it running the project's setup
    /// script in a dedicated terminal. Result:
    /// `{worktree: SupermuxWorktreeDTO, workspace_id?}`.
    @MainActor
    func v2SupermuxWorktreeCreate(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        let model = SupermuxComposition.projectsModel
        let workspaceName = (params["workspace_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var branchName = params["branch_name"] as? String ?? ""
        // Mirror the desktop sheet: AI names the branch only when it was left
        // blank and a workspace name exists; a typed branch is respected
        // verbatim, and any AI failure falls through to the service's own
        // random-name fallback for blank input.
        if branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !workspaceName.isEmpty,
           await model.isAIBranchNamingConfigured(),
           let suggestion = await model.suggestBranchName(forWorkspaceName: workspaceName) {
            branchName = suggestion
        }
        let worktree: SupermuxProjectWorktree
        do {
            worktree = try await model.createWorktree(
                projectId: project.id,
                branchName: branchName,
                baseBranch: nil
            )
        } catch let error as SupermuxGitError {
            return .err(
                code: SupermuxMobileWorktreeErrorCode.wireCode(for: error),
                message: error.localizedDescription,
                data: nil
            )
        } catch {
            return .err(code: "unavailable", message: error.localizedDescription, data: nil)
        }
        var workspaceID: UUID?
        if params["open"] as? Bool == true {
            workspaceID = supermuxOpenWorktreeWorkspace(
                worktree,
                project: project,
                title: workspaceName.isEmpty ? nil : workspaceName,
                runSetup: true,
                params: params
            )
        }
        do {
            var payload: [String: Any] = [
                "worktree": try SupermuxWireJSON().dictionary(from: SupermuxWorktreeDTO(
                    worktree: worktree,
                    isOpen: workspaceID != nil,
                    workspaceId: workspaceID?.uuidString
                )),
            ]
            if let workspaceID {
                payload["workspace_id"] = workspaceID.uuidString
            }
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode created worktree", data: nil)
        }
    }

    /// `mobile.supermux.worktree.open`: opens (or focuses) a workspace in an
    /// existing worktree. Re-opening never re-runs setup — only the
    /// just-created path does, exactly like the desktop. Result:
    /// `{workspace_id}`.
    @MainActor
    func v2SupermuxWorktreeOpen(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        let worktree: SupermuxProjectWorktree
        switch await supermuxResolveWorktree(params: params, projectID: project.id) {
        case let .failure(error): return error
        case let .success(resolved): worktree = resolved
        }
        guard let workspaceID = supermuxOpenWorktreeWorkspace(
            worktree,
            project: project,
            title: nil,
            runSetup: false,
            params: params
        ) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        return .ok(["workspace_id": workspaceID.uuidString])
    }

    /// `mobile.supermux.worktree.remove`: removes a supermux-managed worktree.
    /// A dirty worktree without `force: true` fails with `dirty_worktree`; a
    /// forced removal runs the project's teardown script headlessly first
    /// (both inside ``SupermuxGitWorktreeService``, shared with the desktop).
    @MainActor
    func v2SupermuxWorktreeRemove(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        let worktree: SupermuxProjectWorktree
        switch await supermuxResolveWorktree(params: params, projectID: project.id) {
        case let .failure(error): return error
        case let .success(resolved): worktree = resolved
        }
        let force = params["force"] as? Bool ?? false
        let deleteBranch = params["delete_branch"] as? Bool ?? false
        do {
            try await SupermuxComposition.projectsModel.removeWorktree(
                worktree,
                projectId: project.id,
                force: force,
                deleteBranch: deleteBranch
            )
        } catch let error as SupermuxGitError {
            return .err(
                code: SupermuxMobileWorktreeErrorCode.wireCode(for: error),
                message: error.localizedDescription,
                data: ["worktree_path": worktree.path]
            )
        } catch {
            return .err(code: "unavailable", message: error.localizedDescription, data: nil)
        }
        return .ok([
            "removed": true,
            "worktree_path": worktree.path,
        ])
    }

    // MARK: - Shared pieces

    /// A request param resolved to a domain value, or the wire error to
    /// return (`V2CallResult` is not `Error`, so `Result` cannot carry it).
    enum SupermuxParamResolution<Value> {
        case success(Value)
        case failure(V2CallResult)
    }

    /// Resolves the request's `project_id` to a loaded project record, or the
    /// wire error to return (`invalid_params` / `not_found`).
    @MainActor
    func supermuxResolveProject(params: [String: Any]) async -> SupermuxParamResolution<SupermuxProject> {
        guard let idString = params["project_id"] as? String,
              let projectID = UUID(uuidString: idString) else {
            return .failure(.err(code: "invalid_params", message: "project_id must be a project UUID", data: nil))
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        guard let project = model.projects.first(where: { $0.id == projectID }) else {
            return .failure(.err(code: "not_found", message: "Unknown project", data: [
                "project_id": idString,
            ]))
        }
        return .success(project)
    }

    /// Resolves the request's `worktree_path` against the project's freshly
    /// re-read worktrees (git is the source of truth), or the wire error to
    /// return.
    @MainActor
    private func supermuxResolveWorktree(
        params: [String: Any],
        projectID: UUID
    ) async -> SupermuxParamResolution<SupermuxProjectWorktree> {
        guard let path = params["worktree_path"] as? String, !path.isEmpty else {
            return .failure(.err(code: "invalid_params", message: "worktree_path is required", data: nil))
        }
        let model = SupermuxComposition.projectsModel
        await model.refreshWorktrees(for: projectID)
        let target = (path as NSString).standardizingPath
        guard let worktree = (model.worktreesByProjectId[projectID] ?? [])
            .first(where: { ($0.path as NSString).standardizingPath == target }) else {
            return .failure(.err(code: "not_found", message: "Unknown worktree", data: [
                "worktree_path": path,
            ]))
        }
        return .success(worktree)
    }

    /// Opens a workspace in `worktree` through the same path the desktop uses
    /// (``SupermuxTabManagerOpener``): when `runSetup` is true (only the
    /// just-created path) the project's setup script runs in a dedicated setup
    /// terminal with the worktree environment exported. Mirrors
    /// `SupermuxProjectsSectionView.openWorktree`.
    @MainActor
    private func supermuxOpenWorktreeWorkspace(
        _ worktree: SupermuxProjectWorktree,
        project rawProject: SupermuxProject,
        title: String?,
        runSetup: Bool,
        params: [String: Any]
    ) -> UUID? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        let model = SupermuxComposition.projectsModel
        // Use the model's current record, not the caller's snapshot:
        // `createWorktree` re-imports config.json just before this runs, so
        // the setup script must come from the refreshed project.
        let project = model.projects.first(where: { $0.id == rawProject.id }) ?? rawProject
        model.noteOpened(id: project.id)
        let resolvedTitle = title.map { $0.isEmpty ? worktree.displayName : $0 } ?? worktree.displayName
        let setupScript = runSetup ? SupermuxWorktreeScript.joined(project.setupCommands) : nil
        let setupEnvironment: [String: String] = setupScript == nil
            ? [:]
            : SupermuxWorktreeEnvironment.variables(projectRoot: project.rootPath, worktreePath: worktree.path)
        return SupermuxTabManagerOpener(tabManager: tabManager).openWorkspaceReturningWorkspaceId(
            SupermuxOpenWorkspaceRequest(
                title: resolvedTitle,
                directory: worktree.path,
                colorHex: project.colorHex,
                projectId: project.id,
                setupScript: setupScript,
                setupEnvironment: setupEnvironment
            )
        )
    }

    /// Light snapshots of every open workspace across all main windows, for
    /// worktree open-state matching and the opened-worktree PR fold (cmux's
    /// own per-workspace probe — the same source the desktop rows use).
    @MainActor
    private func supermuxOpenWorkspaceSnapshots() -> [SupermuxOpenWorkspace] {
        guard let app = AppDelegate.shared else { return [] }
        var seenWindowIDs: Set<UUID> = []
        var seenWorkspaceIDs: Set<UUID> = []
        var snapshots: [SupermuxOpenWorkspace] = []
        for summary in app.listMainWindowSummaries() {
            guard seenWindowIDs.insert(summary.windowId).inserted,
                  let windowTabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in windowTabManager.tabs where seenWorkspaceIDs.insert(workspace.id).inserted {
                snapshots.append(SupermuxOpenWorkspace(
                    id: workspace.id,
                    title: workspace.customTitle ?? workspace.title,
                    directory: workspace.currentDirectory,
                    isSelected: false,
                    pullRequest: workspace.sidebarPullRequestsInDisplayOrder().first
                        .flatMap(SupermuxPullRequest.init(sidebarState:))
                ))
            }
        }
        return snapshots
    }
}

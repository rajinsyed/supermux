import CmuxControlSocket
import Foundation
import SupermuxKit
import SupermuxMobileCore
import os

/// `mobile.supermux.agent.*` handlers: the Mac side of the phone's "Start
/// Claude in a new worktree" sheet. Commands, model catalogs, naming, and
/// the worktree launch all run through the SAME objects the desktop sheet
/// uses (``SupermuxComposition/agentLaunch``); the phone only picks and
/// types the prompt.
extension TerminalController {
    private static let supermuxAgentLogger = Logger(subsystem: "com.cmuxterm.app", category: "supermux.agent")

    /// `mobile.supermux.agent.options`: `{project_id?, command?, refresh?}` →
    /// ``SupermuxAgentLaunchOptionsDTO`` (with the additive
    /// `ai_naming_configured`). An unknown `command` falls back to
    /// the Mac's remembered selection; `refresh: true` bypasses the cached
    /// catalog. Never fails on an unreadable catalog — that is reported as
    /// `models_source: unavailable` so the phone can still launch on the CLI
    /// default model.
    @MainActor
    func v2SupermuxAgentOptions(params: [String: Any]) async -> V2CallResult {
        let environment = SupermuxComposition.agentLaunch
        let settings = environment.settings
        let commands = settings.commands
        let requested = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = commands.contains(requested) ? requested : settings.selectedCommand
        let workingDirectory = await supermuxAgentWorkingDirectory(params: params)
        let catalog = await environment.catalog.models(
            for: command,
            workingDirectoryURL: workingDirectory,
            forceRefresh: params["refresh"] as? Bool == true
        )
        let last = settings.lastChoice(for: command)
        let payload = SupermuxAgentLaunchOptionsDTO(
            commands: commands,
            selectedCommand: command,
            models: catalog.models,
            modelsSource: catalog.source,
            modelsError: catalog.errorDescription,
            lastModel: last.model,
            lastEffort: last.effort,
            // Lets another Mac's New Worktree sheet say whether blank names
            // are AI-named here (the key itself never leaves this Mac).
            aiNamingConfigured: await environment.launcher.isAINamingConfigured(),
            // Lets it preview the exact line this Mac's shell will run.
            shellFlavor: environment.launcher.shell.wireName
        )
        do {
            return .ok(try SupermuxWireJSON().dictionary(from: payload))
        } catch {
            return .err(code: "unavailable", message: "Failed to encode agent options", data: nil)
        }
    }

    /// `mobile.supermux.agent.start`: `{project_id, prompt, command?, model?,
    /// effort?, base_branch?, workspace_name?, branch_name?, attachment_paths?}`.
    /// `attachment_paths` names images already uploaded here
    /// (`agent.attachment.upload`); they are listed after the prompt and
    /// their folders made readable to Claude, so any other path (one outside
    /// the attachment store, or not a file) rejects the request. Names the
    /// workspace and branch from the prompt (typed names win),
    /// creates the worktree, and opens a workspace whose first terminal runs
    /// the Claude command with the prompt (setup script in its own terminal,
    /// exactly like the desktop). The open preserves the Mac user's focus per
    /// the socket policy, and `select: false` (another Mac asking) leaves the
    /// selection alone. Result: `{worktree, workspace_id?, workspace_name,
    /// branch_name, named_by_ai}`.
    @MainActor
    func v2SupermuxAgentStart(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        guard let attachmentPaths = supermuxAttachmentPaths(params["attachment_paths"]) else {
            return .err(
                code: "invalid_params",
                message: "attachment_paths must name files uploaded with agent.attachment.upload",
                data: nil
            )
        }
        let environment = SupermuxComposition.agentLaunch
        let requestedCommand = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = environment.settings.commands.contains(requestedCommand)
            ? requestedCommand
            : environment.settings.selectedCommand
        let request = SupermuxAgentLaunchRequest(
            projectId: project.id,
            prompt: params["prompt"] as? String ?? "",
            command: command,
            model: supermuxNonBlank(params["model"]),
            effort: supermuxNonBlank(params["effort"]),
            baseBranch: supermuxNonBlank(params["base_branch"]),
            workspaceName: supermuxNonBlank(params["workspace_name"]),
            branchName: supermuxNonBlank(params["branch_name"]),
            attachmentPaths: attachmentPaths,
            preservesUserFocus: true
        )
        let launch: SupermuxAgentWorktreeLaunch
        do {
            launch = try await environment.launcher.start(request)
        } catch SupermuxAgentLaunchError.emptyPrompt {
            return .err(code: "invalid_params", message: SupermuxAgentLaunchError.emptyPrompt.localizedDescription, data: nil)
        } catch SupermuxAgentLaunchError.unknownProject {
            return .err(code: "not_found", message: "Unknown project", data: ["project_id": project.id.uuidString])
        } catch let error as SupermuxGitError {
            return .err(
                code: SupermuxMobileWorktreeErrorCode.wireCode(for: error),
                message: error.localizedDescription,
                data: nil
            )
        } catch {
            // Diagnostics stay in the Mac log; the phone gets one fixed,
            // localized sentence rather than an arbitrary underlying error.
            Self.supermuxAgentLogger.error(
                "agent.start failed for project \(project.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .err(
                code: "unavailable",
                message: String(
                    localized: "supermux.agent.error.startFailed",
                    defaultValue: "Couldn’t start Claude on the Mac."
                ),
                data: nil
            )
        }
        var workspaceID: UUID?
        if let tabManager = v2ResolveTabManager(params: params) {
            var openRequest = launch.openRequest
            openRequest.selectsWorkspace = supermuxSelectsWorkspace(params: params)
            workspaceID = SupermuxTabManagerOpener(tabManager: tabManager)
                .openWorkspaceReturningWorkspaceId(openRequest)
        }
        do {
            var payload: [String: Any] = [
                "worktree": try SupermuxWireJSON().dictionary(from: SupermuxWorktreeDTO(
                    worktree: launch.worktree,
                    isOpen: workspaceID != nil,
                    workspaceId: workspaceID?.uuidString
                )),
                "workspace_name": launch.names.workspaceName,
                "branch_name": launch.names.branchName,
                "named_by_ai": launch.namedByAI,
            ]
            if let workspaceID {
                payload["workspace_id"] = workspaceID.uuidString
            }
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode agent launch", data: nil)
        }
    }

    // MARK: - Shared pieces

    /// The directory a model probe runs in: the request's project root when it
    /// resolves, otherwise the user's home.
    @MainActor
    private func supermuxAgentWorkingDirectory(params: [String: Any]) async -> URL {
        if let idString = params["project_id"] as? String, let projectID = UUID(uuidString: idString) {
            let model = SupermuxComposition.projectsModel
            await model.loadIfNeeded()
            if let project = model.projects.first(where: { $0.id == projectID }) {
                return URL(fileURLWithPath: project.rootPath, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The files `attachment_paths` names (symlinks resolved), or `nil` when
    /// one is not a regular file inside this Mac's attachment store or there
    /// are more than the attachment limit. Each folder becomes Claude's
    /// `--add-dir`, so nothing else on this Mac may be named.
    private func supermuxAttachmentPaths(_ value: Any?) -> [String]? {
        guard let value else { return [] }
        guard let raw = value as? [Any], raw.count <= SupermuxAgentAttachmentLimits.maximumAttachments else { return nil }
        let store = MobileTaskAttachmentStore.defaultRootURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).resolvingSymlinksInPath().path + "/"
        var paths: [String] = []
        for item in raw {
            guard let path = item as? String, path.hasPrefix("/") else { return nil }
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(store),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            paths.append(resolved.path)
        }
        return paths
    }

    private func supermuxNonBlank(_ value: Any?) -> String? {
        guard let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

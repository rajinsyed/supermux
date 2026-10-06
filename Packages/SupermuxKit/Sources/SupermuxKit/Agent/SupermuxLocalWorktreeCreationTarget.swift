public import Foundation
public import SupermuxMobileCore

/// This Mac as a New Worktree target: exactly the calls the sheet made before
/// it learned about other Macs — the projects model for branches, AI branch
/// names and git, the agent environment for commands, catalogs and the
/// prompt-first launch — then the host's callbacks open the result.
@MainActor
public final class SupermuxLocalWorktreeCreationTarget: SupermuxWorktreeCreationTarget {
    private let model: SupermuxProjectsModel
    private let project: SupermuxProject
    private let agentLaunch: SupermuxAgentLaunchEnvironment?
    private let onCreated: (SupermuxProjectWorktree, String?, Bool) -> Void
    private let onLaunched: (SupermuxAgentWorktreeLaunch) -> Void

    /// Creates the target.
    /// - Parameters:
    ///   - model: Shared projects model that performs the git work.
    ///   - project: The project the worktree is created in.
    ///   - agentLaunch: Claude launch collaborators; `nil` hides the prompt path.
    ///   - onCreated: Opens a plain worktree with the chosen workspace name,
    ///     selecting its workspace when the `Bool` is `true`.
    ///   - onLaunched: Opens a prompt-first launch's `openRequest`.
    public init(
        model: SupermuxProjectsModel,
        project: SupermuxProject,
        agentLaunch: SupermuxAgentLaunchEnvironment?,
        onCreated: @escaping (SupermuxProjectWorktree, String?, Bool) -> Void,
        onLaunched: @escaping (SupermuxAgentWorktreeLaunch) -> Void
    ) {
        self.model = model
        self.project = project
        self.agentLaunch = agentLaunch
        self.onCreated = onCreated
        self.onLaunched = onLaunched
    }

    public var projectID: UUID { project.id }
    public var remoteDeviceName: String? { nil }

    /// The model's current configured default, falling back to the
    /// presentation snapshot only if the project is no longer in the model.
    public var configuredDefaultBranch: String? {
        model.projects.first(where: { $0.id == project.id })?.defaultBranch ?? project.defaultBranch
    }

    public func loadBranches() async throws -> [String] {
        try await model.localBranches(projectId: project.id)
    }

    public func isAINamingConfigured() async -> Bool {
        if let agentLaunch { return await agentLaunch.launcher.isAINamingConfigured() }
        return await model.isAIBranchNamingConfigured()
    }

    public func isAIBranchNamingConfigured() async -> Bool {
        await model.isAIBranchNamingConfigured()
    }

    public func suggestBranchName(forWorkspaceName name: String) async -> String? {
        await model.suggestBranchName(forWorkspaceName: name)
    }

    public func createWorktree(
        branchName: String,
        baseBranch: String?,
        workspaceName: String?,
        selectsWorkspace: Bool
    ) async throws {
        let worktree = try await model.createWorktree(
            projectId: project.id,
            branchName: branchName,
            baseBranch: baseBranch
        )
        // A created worktree is always delivered, dismissed sheet or not.
        onCreated(worktree, workspaceName, selectsWorkspace)
    }

    // MARK: - Prompt-first

    public var supportsAgentLaunch: Bool { agentLaunch != nil }
    public var canEditAgentCommands: Bool { agentLaunch != nil }

    public var initialAgentCommands: SupermuxAgentCommandList {
        guard let settings = agentLaunch?.settings else { return SupermuxAgentCommandList(commands: [], selected: "") }
        return SupermuxAgentCommandList(commands: settings.commands, selected: settings.selectedCommand)
    }

    public func setAgentCommands(_ commands: [String]) -> SupermuxAgentCommandList {
        agentLaunch?.settings.setCommands(commands)
        return initialAgentCommands
    }

    public func rememberAgentCommand(_ command: String) {
        agentLaunch?.settings.setSelectedCommand(command)
    }

    public func agentOptions(for command: String, forceRefresh: Bool) async -> SupermuxAgentLaunchOptionsDTO {
        guard let agentLaunch else {
            return SupermuxAgentLaunchOptionsDTO(commands: [], selectedCommand: command, models: [], modelsSource: .unavailable)
        }
        let result = await agentLaunch.catalog.models(
            for: command,
            workingDirectoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true),
            forceRefresh: forceRefresh
        )
        let last = agentLaunch.settings.lastChoice(for: command)
        return SupermuxAgentLaunchOptionsDTO(
            commands: agentLaunch.settings.commands,
            selectedCommand: command,
            models: result.models,
            modelsSource: result.source,
            modelsError: result.errorDescription,
            lastModel: last.model,
            lastEffort: last.effort
        )
    }

    public func shellLinePreview(command: String, model: String?, effort: String?, prompt: String) -> String? {
        agentLaunch?.launcher.shellLine(command: command, model: model, effort: effort, prompt: prompt)
    }

    public var supportsPromptAttachments: Bool { agentLaunch != nil }

    public func stageAttachments(_ files: [URL]) async throws -> [String] {
        guard let agentLaunch, !files.isEmpty else { return [] }
        return try await agentLaunch.launcher.stageAttachments(files)
    }

    public func startAgent(
        _ request: SupermuxAgentLaunchRequest,
        selectsWorkspace: Bool,
        willCreateWorktree: @escaping @MainActor () -> Void
    ) async throws {
        guard let agentLaunch else { return }
        var launch = try await agentLaunch.launcher.start(request, willCreateWorktree: willCreateWorktree)
        if !selectsWorkspace { launch.openRequest = launch.openRequest.inBackground }
        // The worktree exists now: deliver it even if the sheet was dismissed
        // meanwhile, so it is opened rather than orphaned.
        onLaunched(launch)
    }
}

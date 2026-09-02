public import Foundation

/// What the user asked for when starting Claude in a new worktree.
public struct SupermuxAgentLaunchRequest: Equatable, Sendable {
    /// The owning project.
    public var projectId: UUID
    /// The task Claude starts on.
    public var prompt: String
    /// The Claude command to run (`claude`, `cc`, `ccx`, …).
    public var command: String
    /// A `--model` selector, or `nil` for the CLI default.
    public var model: String?
    /// An `--effort` level, or `nil` for the CLI default.
    public var effort: String?
    /// The branch to start from, or `nil` for the project default / `HEAD`.
    public var baseBranch: String?
    /// Whether the opened workspace must not steal the Mac user's keyboard
    /// focus (remote/phone launches).
    public var preservesUserFocus: Bool

    /// Creates a launch request.
    public init(
        projectId: UUID,
        prompt: String,
        command: String,
        model: String? = nil,
        effort: String? = nil,
        baseBranch: String? = nil,
        preservesUserFocus: Bool = false
    ) {
        self.projectId = projectId
        self.prompt = prompt
        self.command = command
        self.model = model
        self.effort = effort
        self.baseBranch = baseBranch
        self.preservesUserFocus = preservesUserFocus
    }
}

/// The outcome of a launch: the worktree that was created, the names chosen
/// for it, and the workspace-open request the host should perform.
public struct SupermuxAgentWorktreeLaunch: Sendable {
    /// The created worktree.
    public var worktree: SupermuxProjectWorktree
    /// The names the workspace and branch were given.
    public var names: SupermuxPromptNames
    /// Whether the names came from AI (`true`) or the offline heuristic.
    public var namedByAI: Bool
    /// The request to hand to ``SupermuxWorkspaceOpening/openWorkspace(_:)``:
    /// the worktree workspace, titled after the prompt, whose first terminal
    /// runs the Claude command, plus the project's setup script.
    public var openRequest: SupermuxOpenWorkspaceRequest
}

/// Errors ``SupermuxAgentWorktreeLauncher`` raises before touching git.
public enum SupermuxAgentLaunchError: Error, Equatable, Sendable, LocalizedError {
    /// The prompt was blank.
    case emptyPrompt
    /// The project is not registered.
    case unknownProject

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return String(
                localized: "supermux.agent.error.emptyPrompt",
                defaultValue: "Type what Claude should work on first."
            )
        case .unknownProject:
            return String(
                localized: "supermux.agent.error.unknownProject",
                defaultValue: "This project is no longer registered."
            )
        }
    }
}

/// The one shared "start Claude in a new worktree" path behind the Mac sheet
/// and the phone's `agent.start` RPC.
///
/// Names the workspace and branch from the prompt (AI when configured,
/// otherwise ``SupermuxPromptNaming``), creates the worktree through the same
/// ``SupermuxProjectsModel`` call the plain New Worktree flow uses, remembers
/// the model/effort for the command, and returns the open request. It does
/// NOT open the workspace itself: the caller owns the window/tab manager.
@MainActor
public final class SupermuxAgentWorktreeLauncher {
    private let projectsModel: SupermuxProjectsModel
    private let namer: (any SupermuxAIWorktreeNaming)?
    private let settings: SupermuxAgentLauncherSettings

    /// Creates the launcher.
    /// - Parameters:
    ///   - projectsModel: The shared projects model that owns git work.
    ///   - namer: The AI namer, or `nil` to always use the heuristic.
    ///   - settings: Where commands and last choices are remembered.
    public init(
        projectsModel: SupermuxProjectsModel,
        namer: (any SupermuxAIWorktreeNaming)?,
        settings: SupermuxAgentLauncherSettings
    ) {
        self.projectsModel = projectsModel
        self.namer = namer
        self.settings = settings
    }

    /// Whether AI naming will be attempted (a key is configured).
    public func isAINamingConfigured() async -> Bool {
        await namer?.isConfigured() ?? false
    }

    /// Resolves names for `prompt` the way ``start(_:)`` will: AI first when
    /// configured, then the heuristic.
    /// - Returns: The names and whether AI produced them; `nil` for a prompt
    ///   with no usable words.
    public func names(forPrompt prompt: String) async -> (names: SupermuxPromptNames, fromAI: Bool)? {
        if let namer, let aiNames = await namer.suggestNames(forPrompt: prompt) {
            return (aiNames, true)
        }
        return SupermuxPromptNaming.names(from: prompt).map { ($0, false) }
    }

    /// Creates the worktree and builds its open request.
    ///
    /// Cancellation is honored only before git runs (during naming); once
    /// `createWorktree` starts, the worktree is always created and returned.
    /// - Parameters:
    ///   - request: What to launch.
    ///   - willCreateWorktree: Called on the main actor right before git runs
    ///     — the point of no return — so a UI can disable its Cancel button.
    /// - Throws: ``SupermuxAgentLaunchError`` for a blank prompt or unknown
    ///   project, otherwise ``SupermuxGitError`` from worktree creation.
    public func start(
        _ request: SupermuxAgentLaunchRequest,
        willCreateWorktree: (@MainActor () -> Void)? = nil
    ) async throws -> SupermuxAgentWorktreeLaunch {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw SupermuxAgentLaunchError.emptyPrompt }
        await projectsModel.loadIfNeeded()
        guard projectsModel.projects.contains(where: { $0.id == request.projectId }) else {
            throw SupermuxAgentLaunchError.unknownProject
        }
        let resolved = await names(forPrompt: prompt)
            ?? (SupermuxPromptNames(workspaceName: Self.fallbackTitle(for: prompt), branchName: ""), false)
        try Task.checkCancellation()
        willCreateWorktree?()

        // A blank branch lets the service pick a friendly random name — the
        // same fallback the plain sheet has for prompts made only of filler.
        let worktree = try await projectsModel.createWorktree(
            projectId: request.projectId,
            branchName: resolved.names.branchName,
            baseBranch: request.baseBranch
        )
        // The model re-imports config.json inside createWorktree, so read the
        // refreshed record for the setup script.
        guard let project = projectsModel.projects.first(where: { $0.id == request.projectId }) else {
            throw SupermuxAgentLaunchError.unknownProject
        }
        projectsModel.noteOpened(id: project.id)
        settings.setSelectedCommand(request.command)
        settings.recordChoice(command: request.command, model: request.model, effort: request.effort)

        let setupScript = SupermuxWorktreeScript.joined(project.setupCommands)
        let names = SupermuxPromptNames(
            workspaceName: resolved.names.workspaceName,
            branchName: worktree.branch ?? resolved.names.branchName
        )
        let openRequest = SupermuxOpenWorkspaceRequest(
            title: names.workspaceName,
            directory: worktree.path,
            colorHex: project.colorHex,
            initialCommand: SupermuxAgentLaunchCommand.shellLine(
                command: request.command,
                model: request.model,
                effort: request.effort,
                prompt: prompt
            ),
            projectId: project.id,
            setupScript: setupScript,
            setupEnvironment: setupScript == nil
                ? [:]
                : SupermuxWorktreeEnvironment.variables(projectRoot: project.rootPath, worktreePath: worktree.path),
            preservesUserFocus: request.preservesUserFocus
        )
        return SupermuxAgentWorktreeLaunch(
            worktree: worktree,
            names: names,
            namedByAI: resolved.fromAI,
            openRequest: openRequest
        )
    }

    /// A last-resort title when the prompt has no nameable words: its first
    /// few characters.
    static func fallbackTitle(for prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return String(firstLine.prefix(40))
    }
}

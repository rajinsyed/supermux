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
    /// A workspace title typed by the user; blank means "derive from the prompt".
    public var workspaceName: String?
    /// A branch typed by the user; blank means "derive from the prompt".
    public var branchName: String?
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
        workspaceName: String? = nil,
        branchName: String? = nil,
        preservesUserFocus: Bool = false
    ) {
        self.projectId = projectId
        self.prompt = prompt
        self.command = command
        self.model = model
        self.effort = effort
        self.baseBranch = baseBranch
        self.workspaceName = workspaceName
        self.branchName = branchName
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
    /// A long prompt could not be saved to the file the launch line reads.
    case promptFileWriteFailed(String)

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
        case .promptFileWriteFailed(let reason):
            return String(
                localized: "supermux.agent.error.promptFileWriteFailed",
                defaultValue: "Could not save the prompt for Claude: \(reason)"
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
    /// The dialect the new terminal's shell reads the launch line in.
    public let shell: SupermuxShellFlavor
    /// Where prompts too long for the pty's input line are stored (see
    /// ``SupermuxAgentLaunchCommand/maxInputUTF8Length``).
    public let promptFileDirectory: URL

    /// Creates the launcher.
    /// - Parameters:
    ///   - projectsModel: The shared projects model that owns git work.
    ///   - namer: The AI namer, or `nil` to always use the heuristic.
    ///   - settings: Where commands and last choices are remembered.
    ///   - shell: The quoting dialect of the user's shell (`$SHELL`); the
    ///     new workspace's terminal runs that shell and reads the line.
    ///   - promptFileDirectory: Where long prompts are written; defaults to
    ///     a folder under the temporary directory, so the app passes its
    ///     state directory.
    public init(
        projectsModel: SupermuxProjectsModel,
        namer: (any SupermuxAIWorktreeNaming)?,
        settings: SupermuxAgentLauncherSettings,
        shell: SupermuxShellFlavor = .detect(shellPath: SupermuxAgentCommandProbePlan.shellPath()),
        promptFileDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-agent-prompts", isDirectory: true)
    ) {
        self.projectsModel = projectsModel
        self.namer = namer
        self.settings = settings
        self.shell = shell
        self.promptFileDirectory = promptFileDirectory
    }

    /// The exact shell line a launch with these choices would run — the
    /// sheet's preview, built by the same code as the real launch.
    public func shellLine(command: String, model: String?, effort: String?, prompt: String) -> String {
        launchLine(command: command, model: model, effort: effort, prompt: prompt).line
    }

    /// The launch line plus the prompt file it reads when the prompt is too
    /// long to go inline.
    public func launchLine(command: String, model: String?, effort: String?, prompt: String) -> SupermuxAgentLaunchLine {
        SupermuxAgentLaunchCommand.launchLine(
            command: command,
            model: model,
            effort: effort,
            prompt: prompt,
            shell: shell,
            promptFileDirectory: promptFileDirectory
        )
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
    /// - Throws: ``SupermuxAgentLaunchError`` for a blank prompt, unknown
    ///   project, or unwritable prompt file, otherwise ``SupermuxGitError``
    ///   from worktree creation.
    public func start(
        _ request: SupermuxAgentLaunchRequest,
        willCreateWorktree: (@MainActor () -> Void)? = nil
    ) async throws -> SupermuxAgentWorktreeLaunch {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw SupermuxAgentLaunchError.emptyPrompt }
        await projectsModel.loadIfNeeded()
        guard let registeredProject = projectsModel.projects.first(where: { $0.id == request.projectId }) else {
            throw SupermuxAgentLaunchError.unknownProject
        }
        // Typed names win; only the blanks are derived from the prompt (and
        // the AI call is skipped entirely when the user typed both).
        let typedName = Self.normalized(request.workspaceName)
        let typedBranch = Self.normalized(request.branchName)
        var resolved: (names: SupermuxPromptNames, fromAI: Bool)
        if let typedName, let typedBranch {
            resolved = (SupermuxPromptNames(workspaceName: typedName, branchName: typedBranch), false)
        } else {
            resolved = await names(forPrompt: prompt)
                ?? (SupermuxPromptNames(workspaceName: Self.fallbackTitle(for: prompt), branchName: ""), false)
            if let typedName { resolved.names.workspaceName = typedName }
            if let typedBranch { resolved.names.branchName = typedBranch }
        }
        try Task.checkCancellation()
        // A long prompt goes through a file (see SupermuxAgentLaunchCommand);
        // write it before git runs so a failure cannot orphan a worktree.
        let launchLine = launchLine(
            command: request.command,
            model: request.model,
            effort: request.effort,
            prompt: prompt
        )
        if let promptFile = launchLine.promptFile {
            do {
                try SupermuxAgentPromptFileStore.write(promptFile)
            } catch {
                throw SupermuxAgentLaunchError.promptFileWriteFailed(error.localizedDescription)
            }
        }
        willCreateWorktree?()

        // A blank branch lets the service pick a friendly random name — the
        // same fallback the plain sheet has for prompts made only of filler.
        let worktree = try await projectsModel.createWorktree(
            projectId: request.projectId,
            branchName: resolved.names.branchName,
            baseBranch: request.baseBranch
        )
        // The model re-imports config.json inside createWorktree, so prefer
        // the refreshed record for the setup script. Past this point nothing
        // may fail: the worktree exists, so a project removed while git ran
        // falls back to the snapshot taken above rather than orphaning it.
        let project = projectsModel.projects.first(where: { $0.id == request.projectId }) ?? registeredProject
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
            initialCommand: launchLine.line,
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

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A last-resort title when the prompt has no nameable words: its first
    /// few characters.
    static func fallbackTitle(for prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return String(firstLine.prefix(40))
    }
}

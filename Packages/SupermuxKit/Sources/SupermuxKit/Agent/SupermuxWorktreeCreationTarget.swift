public import Foundation
public import SupermuxMobileCore

/// The Claude commands a Mac offers, and the one to preselect.
public struct SupermuxAgentCommandList: Equatable, Sendable {
    /// The commands in display order (empty until another Mac answered).
    public var commands: [String]
    /// The preselected command (`""` when not known yet).
    public var selected: String

    /// Creates the list.
    public init(commands: [String], selected: String) {
        self.commands = commands
        self.selected = selected
    }
}

/// Where the New Worktree sheet creates: one Mac's copy of a project.
///
/// The sheet (through ``SupermuxNewWorktreeSheetModel``) only talks to this
/// seam, so "This Mac" and another Mac run the same flow. This Mac's
/// implementation is ``SupermuxLocalWorktreeCreationTarget`` (the projects
/// model, the local AI namer and catalog, and the host's workspace opener);
/// the app target implements another Mac over its device link
/// (`worktrees.list`, `worktree.suggest_branch`, `agent.options`,
/// `worktree.create {open: true}`, `agent.start`), then opens that Mac's new
/// workspace here as a mirror.
///
/// Both creates deliver the worktree even when the sheet is already gone:
/// once they return (or throw), the worktree exists and its workspace is
/// being opened, or nothing happened.
@MainActor
public protocol SupermuxWorktreeCreationTarget: AnyObject, Sendable {
    /// The project's id on THAT Mac (used in its RPCs and launch requests).
    var projectID: UUID { get }
    /// The other Mac's name for progress text; `nil` for this Mac.
    var remoteDeviceName: String? { get }
    /// The project's configured default starting branch on that Mac.
    var configuredDefaultBranch: String? { get }

    /// That Mac's local branches (the starting-branch menu).
    func loadBranches() async throws -> [String]
    /// Whether that Mac names blank fields with AI (hint and status text).
    func isAINamingConfigured() async -> Bool
    /// Whether the plain path should ask for an AI branch name before creating.
    func isAIBranchNamingConfigured() async -> Bool
    /// An AI branch name for a workspace name; `nil` falls back to the
    /// create's own random name.
    func suggestBranchName(forWorkspaceName name: String) async -> String?
    /// Creates a plain worktree there and opens its workspace.
    /// - Parameters:
    ///   - branchName: The branch (blank lets that Mac pick a random name).
    ///   - baseBranch: An explicit starting branch, `HEAD`, or `nil` for the
    ///     project default.
    ///   - workspaceName: The workspace title, `nil` to name it after the branch.
    func createWorktree(branchName: String, baseBranch: String?, workspaceName: String?) async throws

    /// Whether the prompt-first ("Start Claude") path is offered there.
    var supportsAgentLaunch: Bool { get }
    /// Whether the command list can be edited from this Mac's sheet.
    var canEditAgentCommands: Bool { get }
    /// Commands known without a round trip (another Mac: empty until
    /// ``agentOptions(for:forceRefresh:)`` answered once).
    var initialAgentCommands: SupermuxAgentCommandList { get }
    /// Replaces the command list (only when ``canEditAgentCommands``).
    func setAgentCommands(_ commands: [String]) -> SupermuxAgentCommandList
    /// Remembers the command the user picked.
    func rememberAgentCommand(_ command: String)
    /// The model catalog and remembered choice for `command` (`""` lets that
    /// Mac pick its selected command). Never throws: failures come back as
    /// `modelsSource == .unavailable` with a message.
    func agentOptions(for command: String, forceRefresh: Bool) async -> SupermuxAgentLaunchOptionsDTO
    /// The exact shell line a launch would type, or `nil` when it is not
    /// known here (another Mac's shell builds it).
    func shellLinePreview(command: String, model: String?, effort: String?, prompt: String) -> String?
    /// Names, creates and opens a worktree whose terminal runs the command.
    /// Calls `willCreateWorktree` right before the point of no return.
    func startAgent(
        _ request: SupermuxAgentLaunchRequest,
        willCreateWorktree: @escaping @MainActor () -> Void
    ) async throws
}

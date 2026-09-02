public import SupermuxMobileCore

/// `mobile.supermux.agent.start` result:
/// `{worktree, workspace_id?, workspace_name, branch_name, named_by_ai}`.
/// Every field decodes leniently so a partial host never breaks the phone.
public struct SupermuxAgentStartResponse: Codable, Sendable, Equatable {
    /// The created worktree, when the Mac reported it.
    public var worktree: SupermuxWorktreeDTO?
    /// The opened workspace's id, when the Mac opened one.
    public var workspaceId: String?
    /// The title the workspace was given.
    public var workspaceName: String?
    /// The branch the worktree was created on.
    public var branchName: String?
    /// Whether AI (rather than the offline heuristic) chose the names.
    public var namedByAI: Bool?

    /// Creates a response value (used by tests and fakes).
    public init(
        worktree: SupermuxWorktreeDTO? = nil,
        workspaceId: String? = nil,
        workspaceName: String? = nil,
        branchName: String? = nil,
        namedByAI: Bool? = nil
    ) {
        self.worktree = worktree
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.branchName = branchName
        self.namedByAI = namedByAI
    }

    private enum CodingKeys: String, CodingKey {
        case worktree
        case workspaceId = "workspace_id"
        case workspaceName = "workspace_name"
        case branchName = "branch_name"
        case namedByAI = "named_by_ai"
    }
}

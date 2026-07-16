/// Wire representation of one git worktree belonging to a project.
///
/// Only ``path`` (the identity) is required; everything else is optional so
/// old peers tolerate additions and omissions.
public struct SupermuxWorktreeDTO: Codable, Sendable, Equatable {
    /// Absolute worktree path on the Mac; the stable identity.
    public var path: String
    /// Checked-out branch, or `nil` when detached.
    public var branch: String?
    /// Branch the worktree was created from, when recorded.
    public var baseBranch: String?
    /// Whether a workspace is currently open in this worktree.
    public var isOpen: Bool?
    /// The open workspace's id, when ``isOpen`` is true.
    public var workspaceId: String?
    /// Whether the worktree has uncommitted changes.
    public var isDirty: Bool?
    /// The associated pull request, when one is known.
    public var pullRequest: SupermuxPullRequestDTO?

    /// Creates a worktree DTO.
    /// - Parameters:
    ///   - path: Absolute worktree path on the Mac.
    ///   - branch: Optional checked-out branch.
    ///   - baseBranch: Optional base branch.
    ///   - isOpen: Optional open-workspace flag.
    ///   - workspaceId: Optional open workspace id.
    ///   - isDirty: Optional dirty flag.
    ///   - pullRequest: Optional associated pull request.
    public init(
        path: String,
        branch: String? = nil,
        baseBranch: String? = nil,
        isOpen: Bool? = nil,
        workspaceId: String? = nil,
        isDirty: Bool? = nil,
        pullRequest: SupermuxPullRequestDTO? = nil
    ) {
        self.path = path
        self.branch = branch
        self.baseBranch = baseBranch
        self.isOpen = isOpen
        self.workspaceId = workspaceId
        self.isDirty = isDirty
        self.pullRequest = pullRequest
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case branch
        case baseBranch = "base_branch"
        case isOpen = "is_open"
        case workspaceId = "workspace_id"
        case isDirty = "is_dirty"
        case pullRequest = "pull_request"
    }
}

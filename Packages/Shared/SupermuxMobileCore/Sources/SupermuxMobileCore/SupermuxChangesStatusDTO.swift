/// Wire representation of a workspace repository's working-tree status.
///
/// Mirrors the Mac's `SupermuxGitStatusSnapshot`. Every field is optional so
/// old peers tolerate additions and omissions.
public struct SupermuxChangesStatusDTO: Codable, Sendable, Equatable {
    /// The workspace whose repository this snapshot describes.
    public var workspaceId: String?
    /// Whether the workspace directory is a git repository.
    public var isRepository: Bool?
    /// Current branch name, or `nil` when detached or not a repository.
    public var branch: String?
    /// Upstream branch (e.g. `origin/main`), or `nil` when none is set.
    public var upstreamBranch: String?
    /// Commits ahead of the upstream.
    public var ahead: Int?
    /// Commits behind the upstream.
    public var behind: Int?
    /// Changes staged in the index.
    public var staged: [SupermuxChangedFileDTO]?
    /// Tracked-file changes in the working tree that are not staged.
    public var unstaged: [SupermuxChangedFileDTO]?
    /// Files git does not track yet.
    public var untracked: [SupermuxChangedFileDTO]?
    /// Number of entries on the stash.
    public var stashCount: Int?

    /// Creates a changes-status DTO.
    /// - Parameters:
    ///   - workspaceId: Optional workspace id.
    ///   - isRepository: Optional is-a-repository flag.
    ///   - branch: Optional current branch.
    ///   - upstreamBranch: Optional upstream branch.
    ///   - ahead: Optional ahead count.
    ///   - behind: Optional behind count.
    ///   - staged: Optional staged changes.
    ///   - unstaged: Optional unstaged changes.
    ///   - untracked: Optional untracked files.
    ///   - stashCount: Optional stash entry count.
    public init(
        workspaceId: String? = nil,
        isRepository: Bool? = nil,
        branch: String? = nil,
        upstreamBranch: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        staged: [SupermuxChangedFileDTO]? = nil,
        unstaged: [SupermuxChangedFileDTO]? = nil,
        untracked: [SupermuxChangedFileDTO]? = nil,
        stashCount: Int? = nil
    ) {
        self.workspaceId = workspaceId
        self.isRepository = isRepository
        self.branch = branch
        self.upstreamBranch = upstreamBranch
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.stashCount = stashCount
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case isRepository = "is_repository"
        case branch
        case upstreamBranch = "upstream_branch"
        case ahead
        case behind
        case staged
        case unstaged
        case untracked
        case stashCount = "stash_count"
    }
}

public import SupermuxMobileCore

/// Typed decoders for the `mobile.supermux.worktree(s).*` RPC results, exactly
/// as `SupermuxMobileHost+Worktrees.swift` emits them. Every non-essential
/// field decodes leniently so old or partial hosts never break the phone.

/// `mobile.supermux.worktrees.list` result:
/// `{worktrees: [SupermuxWorktreeDTO], branches?: [String]}`.
public struct SupermuxWorktreesListResponse: Codable, Sendable, Equatable {
    /// The project's worktrees, in the Mac's order. Missing decodes as `[]`.
    public var worktrees: [SupermuxWorktreeDTO]
    /// Local branches available as worktree starting points, most recently
    /// committed first. `nil` means the host omitted or could not decode the
    /// additive field (including older hosts without branch selection).
    public var branches: [String]?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - worktrees: The project's worktrees.
    ///   - branches: Local branches available as starting points, when requested.
    public init(worktrees: [SupermuxWorktreeDTO], branches: [String]? = nil) {
        self.worktrees = worktrees
        self.branches = branches
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktrees = (try container.decodeIfPresent([SupermuxWorktreeDTO].self, forKey: .worktrees)) ?? []
        branches = try? container.decode([String].self, forKey: .branches)
    }

    private enum CodingKeys: String, CodingKey {
        case worktrees
        case branches
    }
}

/// `mobile.supermux.worktree.suggest_branch` result: `{branch_name, source}`.
public struct SupermuxBranchSuggestionResponse: Codable, Sendable, Equatable {
    /// The suggested branch name (the response's whole point — required).
    public var branchName: String
    /// Where the name came from: `"ai"` or `"random"`.
    public var source: String?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - branchName: The suggested branch name.
    ///   - source: Where the name came from.
    public init(branchName: String, source: String? = nil) {
        self.branchName = branchName
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case branchName = "branch_name"
        case source
    }
}

/// `mobile.supermux.worktree.create` result:
/// `{worktree: SupermuxWorktreeDTO, workspace_id?}`.
public struct SupermuxWorktreeCreateResponse: Codable, Sendable, Equatable {
    /// The created worktree, when the Mac reported it.
    public var worktree: SupermuxWorktreeDTO?
    /// The opened workspace's id, when `open: true` was requested.
    public var workspaceId: String?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - worktree: The created worktree.
    ///   - workspaceId: The opened workspace's id.
    public init(worktree: SupermuxWorktreeDTO? = nil, workspaceId: String? = nil) {
        self.worktree = worktree
        self.workspaceId = workspaceId
    }

    private enum CodingKeys: String, CodingKey {
        case worktree
        case workspaceId = "workspace_id"
    }
}

/// `mobile.supermux.worktree.open` result: `{workspace_id}`.
public struct SupermuxWorktreeOpenResponse: Codable, Sendable, Equatable {
    /// The opened (or focused) workspace's id.
    public var workspaceId: String?

    /// Creates a response value (used by tests and fakes).
    /// - Parameter workspaceId: The opened workspace's id.
    public init(workspaceId: String? = nil) {
        self.workspaceId = workspaceId
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
    }
}

/// `mobile.supermux.worktree.remove` result: `{removed, worktree_path}`.
public struct SupermuxWorktreeRemoveResponse: Codable, Sendable, Equatable {
    /// Whether the worktree was removed.
    public var removed: Bool?
    /// The removed worktree's path.
    public var worktreePath: String?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - removed: Whether the worktree was removed.
    ///   - worktreePath: The removed worktree's path.
    public init(removed: Bool? = nil, worktreePath: String? = nil) {
        self.removed = removed
        self.worktreePath = worktreePath
    }

    private enum CodingKeys: String, CodingKey {
        case removed
        case worktreePath = "worktree_path"
    }
}

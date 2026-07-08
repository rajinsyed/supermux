public import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.worktree(s).*` methods.
///
/// Each value owns its exact wire shape (`wireMethod` + `wireParams`), so the
/// SAME mapping that ``SupermuxMacClient`` sends is what fakes record and
/// tests assert against (UI-03: recorded calls match architecture §2
/// exactly). Optional params are omitted — never sent as empty strings — to
/// match the Mac handlers' expectations.

/// `mobile.supermux.worktrees.list`: `{project_id}`.
public struct SupermuxWorktreesListRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String

    /// Creates the request.
    /// - Parameter projectID: The project's UUID string.
    public init(projectID: String) {
        self.projectID = projectID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.worktreesList.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["project_id": projectID]
    }
}

/// `mobile.supermux.worktree.suggest_branch`: `{workspace_name?}`.
public struct SupermuxWorktreeSuggestBranchRequest: Equatable, Sendable {
    /// The workspace name the AI derives the branch from, when present.
    public let workspaceName: String?

    /// Creates the request.
    /// - Parameter workspaceName: Optional workspace name to derive from.
    public init(workspaceName: String?) {
        self.workspaceName = workspaceName
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.worktreeSuggestBranch.rawValue }

    /// The exact wire params (`workspace_name` omitted when absent).
    public var wireParams: [String: Any] {
        var params: [String: Any] = [:]
        if let workspaceName {
            params["workspace_name"] = workspaceName
        }
        return params
    }
}

/// `mobile.supermux.worktree.create`:
/// `{project_id, workspace_name?, branch_name?, open}`.
public struct SupermuxWorktreeCreateRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String
    /// Workspace title (and AI branch-naming input) when present.
    public let workspaceName: String?
    /// Explicit branch name; absent lets the Mac name the branch (AI when
    /// configured, friendly-random otherwise).
    public let branchName: String?
    /// Whether the Mac opens a workspace in the new worktree.
    public let open: Bool

    /// Creates the request.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - workspaceName: Optional workspace title.
    ///   - branchName: Optional explicit branch name.
    ///   - open: Whether to open a workspace after creating.
    public init(projectID: String, workspaceName: String?, branchName: String?, open: Bool) {
        self.projectID = projectID
        self.workspaceName = workspaceName
        self.branchName = branchName
        self.open = open
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.worktreeCreate.rawValue }

    /// The exact wire params (optionals omitted when absent).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["project_id": projectID, "open": open]
        if let workspaceName {
            params["workspace_name"] = workspaceName
        }
        if let branchName {
            params["branch_name"] = branchName
        }
        return params
    }
}

/// `mobile.supermux.worktree.open`: `{project_id, worktree_path}`.
public struct SupermuxWorktreeOpenRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String
    /// Absolute path of the worktree on the Mac.
    public let worktreePath: String

    /// Creates the request.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - worktreePath: Absolute worktree path on the Mac.
    public init(projectID: String, worktreePath: String) {
        self.projectID = projectID
        self.worktreePath = worktreePath
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.worktreeOpen.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["project_id": projectID, "worktree_path": worktreePath]
    }
}

/// `mobile.supermux.worktree.remove`: `{project_id, worktree_path, force?}`.
public struct SupermuxWorktreeRemoveRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String
    /// Absolute path of the worktree on the Mac.
    public let worktreePath: String
    /// Whether to remove despite uncommitted changes. `false` is omitted from
    /// the wire so a plain remove carries no `force` key at all.
    public let force: Bool

    /// Creates the request.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - worktreePath: Absolute worktree path on the Mac.
    ///   - force: Whether to remove despite uncommitted changes.
    public init(projectID: String, worktreePath: String, force: Bool) {
        self.projectID = projectID
        self.worktreePath = worktreePath
        self.force = force
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.worktreeRemove.rawValue }

    /// The exact wire params (`force` present only when `true`).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["project_id": projectID, "worktree_path": worktreePath]
        if force {
            params["force"] = true
        }
        return params
    }
}

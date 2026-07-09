public import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.changes.*` commit/sync/
/// history methods (m3-f2's wire shapes).
///
/// Each value owns its exact wire shape (`wireMethod` + `wireParams`), so the
/// SAME mapping ``SupermuxMacClient`` sends is what fakes record and tests
/// assert against (UI-04). Optional params are omitted — never sent as
/// defaults — to match the Mac handlers' expectations.

/// The extended per-request RPC deadline for the network-bound sync methods.
///
/// The Mac serves `changes.push`/`changes.pull` under its own 120 s git
/// network timeout, which exceeds the phone's 30 s default RPC deadline
/// (`CMUXMobileRuntime`), so the phone must extend the deadline to >= 130 s
/// or it times out while the Mac's push is still legitimately running
/// (m3-f2 handoff). 180 s leaves generous margin.
public enum SupermuxChangesSyncDeadline {
    /// Per-request deadline override for `changes.push` / `changes.pull`.
    public static let rpcTimeoutNanoseconds: UInt64 = 180_000_000_000
}

/// `mobile.supermux.changes.commit`: `{workspace_id, message, stage_all?}`.
///
/// The Mac validates a non-empty trimmed message (`invalid_params`), commits
/// the staged files (everything when `stage_all`), and answers `{sha}`.
public struct SupermuxChangesCommitRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// The commit message (already trimmed by the store).
    public let message: String
    /// Whether the Mac stages every change before committing. `false` is
    /// omitted from the wire.
    public let stageAll: Bool

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - message: The commit message.
    ///   - stageAll: Whether to stage everything before committing.
    public init(workspaceID: String, message: String, stageAll: Bool = false) {
        self.workspaceID = workspaceID
        self.message = message
        self.stageAll = stageAll
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesCommit.rawValue }

    /// The exact wire params (`stage_all` present only when `true`).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID, "message": message]
        if stageAll {
            params["stage_all"] = true
        }
        return params
    }
}

/// `mobile.supermux.changes.generate_commit_message`: `{workspace_id}`.
///
/// Runs entirely Mac-side (the AI key never crosses the wire) and answers
/// `{message}`, or the `ai_unavailable` error for both the no-key and the
/// failed-generation case (distinct messages — the phone surfaces them).
public struct SupermuxChangesGenerateCommitMessageRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String

    /// Creates the request.
    /// - Parameter workspaceID: The workspace's UUID string.
    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesGenerateCommitMessage.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["workspace_id": workspaceID]
    }
}

/// `mobile.supermux.changes.push`: `{workspace_id}` → `{ok, log_lines}`.
///
/// First push sets `-u origin HEAD` Mac-side; the phone sends the extended
/// ``SupermuxChangesSyncDeadline`` because the Mac's git network timeout
/// (120 s) exceeds the default RPC deadline.
public struct SupermuxChangesPushRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String

    /// Creates the request.
    /// - Parameter workspaceID: The workspace's UUID string.
    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesPush.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["workspace_id": workspaceID]
    }

    /// The per-request RPC deadline override (transport-level, not a wire
    /// param) — `nil` would mean the runtime default, which is too short.
    public var rpcTimeoutNanoseconds: UInt64? {
        SupermuxChangesSyncDeadline.rpcTimeoutNanoseconds
    }
}

/// `mobile.supermux.changes.pull`: `{workspace_id}` → `{ok, log_lines}`.
/// Same extended deadline rationale as ``SupermuxChangesPushRequest``.
public struct SupermuxChangesPullRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String

    /// Creates the request.
    /// - Parameter workspaceID: The workspace's UUID string.
    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesPull.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["workspace_id": workspaceID]
    }

    /// The per-request RPC deadline override (transport-level, not a wire
    /// param) — `nil` would mean the runtime default, which is too short.
    public var rpcTimeoutNanoseconds: UInt64? {
        SupermuxChangesSyncDeadline.rpcTimeoutNanoseconds
    }
}

/// `mobile.supermux.changes.stash`: `{workspace_id, message?,
/// include_untracked?}` → `{ok, log_lines}`.
public struct SupermuxChangesStashRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// Optional stash message (`-m` Mac-side when non-nil).
    public let message: String?
    /// Whether untracked files ride along (`git stash -u`). `false` — the
    /// desktop's plain "Stash Changes" — is omitted from the wire.
    public let includeUntracked: Bool

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - message: Optional stash message.
    ///   - includeUntracked: Whether untracked files ride along.
    public init(workspaceID: String, message: String? = nil, includeUntracked: Bool = false) {
        self.workspaceID = workspaceID
        self.message = message
        self.includeUntracked = includeUntracked
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesStash.rawValue }

    /// The exact wire params (optionals present only when set).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID]
        if let message {
            params["message"] = message
        }
        if includeUntracked {
            params["include_untracked"] = true
        }
        return params
    }
}

/// `mobile.supermux.changes.stash_pop`: `{workspace_id}` → `{ok, log_lines}`.
public struct SupermuxChangesStashPopRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String

    /// Creates the request.
    /// - Parameter workspaceID: The workspace's UUID string.
    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesStashPop.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["workspace_id": workspaceID]
    }
}

/// `mobile.supermux.changes.history`: `{workspace_id, limit?, cursor?}`.
///
/// `cursor` is the previous page's `next_cursor` passed back verbatim;
/// `limit` omitted means the Mac's default (50). Incoming commits ride the
/// FIRST page only.
public struct SupermuxChangesHistoryRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// Optional page size (Mac clamps to 1...200; omitted → 50).
    public let limit: Int?
    /// Optional pagination cursor from the previous page.
    public let cursor: String?

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - limit: Optional page size.
    ///   - cursor: Optional pagination cursor.
    public init(workspaceID: String, limit: Int? = nil, cursor: String? = nil) {
        self.workspaceID = workspaceID
        self.limit = limit
        self.cursor = cursor
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesHistory.rawValue }

    /// The exact wire params (optionals present only when set).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID]
        if let limit {
            params["limit"] = limit
        }
        if let cursor {
            params["cursor"] = cursor
        }
        return params
    }
}

public import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.changes.*` read/stage
/// methods.
///
/// Each value owns its exact wire shape (`wireMethod` + `wireParams`), so the
/// SAME mapping that ``SupermuxMacClient`` sends is what fakes record and
/// tests assert against (UI-04: recorded calls match architecture §2
/// exactly). Optional params are omitted — never sent as defaults — to match
/// the Mac handlers' expectations.

/// `mobile.supermux.changes.watch`: `{workspace_id, enable, client_id?}`.
///
/// `enable: true` starts (or heartbeats) the Mac's per-workspace repository
/// watcher; the lease TTL is 120 s server-side, so the phone re-sends every
/// 60 s while the screen is foregrounded. `enable: false` stops it.
/// `client_id` identifies THIS device's watch session so the Mac can
/// refcount watchers per client — one device closing its Changes sheet must
/// not kill another device's live watcher. Omitted (old callers) means the
/// Mac's legacy single-holder behavior.
public struct SupermuxChangesWatchRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// Whether to start/renew (`true`) or stop (`false`) the watcher.
    public let enable: Bool
    /// This device's stable watch-session id, for the Mac's per-client
    /// refcount. `nil` is omitted from the wire (legacy behavior).
    public let clientID: String?

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - enable: Whether to start/renew or stop the watcher.
    ///   - clientID: This device's stable watch-session id, if any.
    public init(workspaceID: String, enable: Bool, clientID: String? = nil) {
        self.workspaceID = workspaceID
        self.enable = enable
        self.clientID = clientID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesWatch.rawValue }

    /// The exact wire params (`client_id` present only when set).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID, "enable": enable]
        if let clientID {
            params["client_id"] = clientID
        }
        return params
    }
}

/// `mobile.supermux.changes.status`: `{workspace_id}`.
public struct SupermuxChangesStatusRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String

    /// Creates the request.
    /// - Parameter workspaceID: The workspace's UUID string.
    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesStatus.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["workspace_id": workspaceID]
    }
}

/// `mobile.supermux.changes.diff`: `{workspace_id, path, staged?}`.
public struct SupermuxChangesDiffRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// Repo-root-relative path of the file to diff.
    public let path: String
    /// Whether to diff the staged (index) side. `false` is omitted from the
    /// wire — the Mac defaults a missing `staged` to the working tree.
    public let staged: Bool

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - path: Repo-root-relative file path.
    ///   - staged: Whether to diff the staged side.
    public init(workspaceID: String, path: String, staged: Bool) {
        self.workspaceID = workspaceID
        self.path = path
        self.staged = staged
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesDiff.rawValue }

    /// The exact wire params (`staged` present only when `true`).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID, "path": path]
        if staged {
            params["staged"] = true
        }
        return params
    }
}

/// Which files a stage/unstage request covers: an explicit repo-root-relative
/// path list, or everything (`all: true` on the wire).
public enum SupermuxChangesSelection: Equatable, Sendable {
    /// Every eligible file.
    case all
    /// The given repo-root-relative paths.
    case paths([String])

    /// Folds the selection into the request's wire params.
    fileprivate func encode(into params: inout [String: Any]) {
        switch self {
        case .all:
            params["all"] = true
        case let .paths(paths):
            params["paths"] = paths
        }
    }
}

/// `mobile.supermux.changes.stage`: `{workspace_id, paths | all,
/// expected_root?}`.
public struct SupermuxChangesStageRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// Which files to stage.
    public let selection: SupermuxChangesSelection
    /// The repo root this mutation was composed against (stale-view pin);
    /// `nil` is omitted from the wire. See ``SupermuxChangesCommitRequest``.
    public let expectedRoot: String?

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - selection: Which files to stage.
    ///   - expectedRoot: The repo root the view was composed against.
    public init(workspaceID: String, selection: SupermuxChangesSelection, expectedRoot: String? = nil) {
        self.workspaceID = workspaceID
        self.selection = selection
        self.expectedRoot = expectedRoot
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesStage.rawValue }

    /// The exact wire params (`expected_root` present only when set).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID]
        selection.encode(into: &params)
        if let expectedRoot {
            params["expected_root"] = expectedRoot
        }
        return params
    }
}

/// `mobile.supermux.changes.unstage`: `{workspace_id, paths | all,
/// expected_root?}`.
public struct SupermuxChangesUnstageRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// Which files to unstage.
    public let selection: SupermuxChangesSelection
    /// The repo root this mutation was composed against (stale-view pin);
    /// `nil` is omitted from the wire. See ``SupermuxChangesCommitRequest``.
    public let expectedRoot: String?

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - selection: Which files to unstage.
    ///   - expectedRoot: The repo root the view was composed against.
    public init(workspaceID: String, selection: SupermuxChangesSelection, expectedRoot: String? = nil) {
        self.workspaceID = workspaceID
        self.selection = selection
        self.expectedRoot = expectedRoot
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesUnstage.rawValue }

    /// The exact wire params (`expected_root` present only when set).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID]
        selection.encode(into: &params)
        if let expectedRoot {
            params["expected_root"] = expectedRoot
        }
        return params
    }
}

/// `mobile.supermux.changes.discard`: `{workspace_id, paths,
/// expected_root?}`.
///
/// Discard is destructive: tracked files are restored to HEAD content;
/// untracked files are DELETED on the Mac (desktop parity). The phone always
/// confirms first; the Mac re-validates every path regardless.
public struct SupermuxChangesDiscardRequest: Equatable, Sendable {
    /// The workspace's UUID string.
    public let workspaceID: String
    /// The repo-root-relative paths to discard (must be non-empty).
    public let paths: [String]
    /// The repo root this mutation was composed against (stale-view pin);
    /// `nil` is omitted from the wire. See ``SupermuxChangesCommitRequest``.
    public let expectedRoot: String?

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The workspace's UUID string.
    ///   - paths: The repo-root-relative paths to discard.
    ///   - expectedRoot: The repo root the view was composed against.
    public init(workspaceID: String, paths: [String], expectedRoot: String? = nil) {
        self.workspaceID = workspaceID
        self.paths = paths
        self.expectedRoot = expectedRoot
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.changesDiscard.rawValue }

    /// The exact wire params (`expected_root` present only when set).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["workspace_id": workspaceID, "paths": paths]
        if let expectedRoot {
            params["expected_root"] = expectedRoot
        }
        return params
    }
}

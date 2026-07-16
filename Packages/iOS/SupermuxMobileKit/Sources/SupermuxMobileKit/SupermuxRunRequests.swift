public import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.run.*`, `preset.launch`,
/// and `action.run` methods.
///
/// Each value owns its exact wire shape (`wireMethod` + `wireParams`), so the
/// SAME mapping ``SupermuxMacClient`` sends is what fakes record and tests
/// assert against (RPC-RUN-01: recorded calls match the committed m4-f1 wire
/// contract exactly). Optional params are omitted — never sent as empty
/// values — to match the Mac handlers' expectations.

/// `mobile.supermux.run.state`: `{}` — one row per registered project.
public struct SupermuxRunStateRequest: Equatable, Sendable {
    /// Creates the request.
    public init() {}

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.runState.rawValue }

    /// The exact wire params (none).
    public var wireParams: [String: Any] { [:] }
}

/// `mobile.supermux.run.start`: `{project_id, command_id?}`.
///
/// `commandID` is the 0-BASED INDEX into the project's `run_commands` array
/// exactly as `projects.list` delivers it. Absent means desktop ⌘G
/// semantics: every configured run command trimmed and chained with `&&`.
public struct SupermuxRunStartRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String
    /// The chosen run command's 0-based index, or `nil` for the default
    /// all-commands start.
    public let commandID: Int?

    /// Creates the request.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - commandID: Optional 0-based `run_commands` index.
    public init(projectID: String, commandID: Int? = nil) {
        self.projectID = projectID
        self.commandID = commandID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.runStart.rawValue }

    /// The exact wire params (`command_id` omitted when absent).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["project_id": projectID]
        if let commandID {
            params["command_id"] = commandID
        }
        return params
    }
}

/// `mobile.supermux.run.stop`: `{project_id}`.
public struct SupermuxRunStopRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String

    /// Creates the request.
    /// - Parameter projectID: The project's UUID string.
    public init(projectID: String) {
        self.projectID = projectID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.runStop.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["project_id": projectID]
    }
}

/// `mobile.supermux.preset.launch`: `{preset_id, project_id?|workspace_id?}`
/// — the Mac requires EXACTLY ONE of the two target keys, so the target is a
/// closed choice here rather than two independent optionals.
public struct SupermuxPresetLaunchRequest: Equatable, Sendable {
    /// Where the preset's terminal opens on the Mac.
    public enum Target: Equatable, Sendable {
        /// A workspace opened (or focused) at the project's root.
        case project(id: String)
        /// An already-open workspace.
        case workspace(id: String)
    }

    /// The preset's UUID string.
    public let presetID: String
    /// The launch target (exactly one of project/workspace).
    public let target: Target

    /// Creates the request.
    /// - Parameters:
    ///   - presetID: The preset's UUID string.
    ///   - target: The launch target.
    public init(presetID: String, target: Target) {
        self.presetID = presetID
        self.target = target
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.presetLaunch.rawValue }

    /// The exact wire params (exactly one target key).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["preset_id": presetID]
        switch target {
        case let .project(id):
            params["project_id"] = id
        case let .workspace(id):
            params["workspace_id"] = id
        }
        return params
    }
}

/// `mobile.supermux.action.run`: `{project_id, action_id}`.
public struct SupermuxActionRunRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String
    /// The action's UUID string.
    public let actionID: String

    /// Creates the request.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - actionID: The action's UUID string.
    public init(projectID: String, actionID: String) {
        self.projectID = projectID
        self.actionID = actionID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.actionRun.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["project_id": projectID, "action_id": actionID]
    }
}

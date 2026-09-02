internal import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.agent.*` methods. Each owns
/// its exact wire shape so fakes record what ``SupermuxMacClient`` sends.
/// Optional params are omitted — never sent as empty strings.

/// `mobile.supermux.agent.options`: `{project_id?, command?, refresh?}`.
public struct SupermuxAgentOptionsRequest: Equatable, Sendable {
    /// The project whose root the model probe runs in, when known.
    public let projectID: String?
    /// The command to describe; absent means the Mac's remembered selection.
    public let command: String?
    /// Whether to bypass the Mac's cached catalog.
    public let refresh: Bool

    /// Creates the request.
    public init(projectID: String? = nil, command: String? = nil, refresh: Bool = false) {
        self.projectID = projectID
        self.command = command
        self.refresh = refresh
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.agentOptions.rawValue }

    /// The exact wire params (optionals omitted; `refresh` only when true).
    public var wireParams: [String: Any] {
        var params: [String: Any] = [:]
        if let projectID { params["project_id"] = projectID }
        if let command { params["command"] = command }
        if refresh { params["refresh"] = true }
        return params
    }
}

/// `mobile.supermux.agent.start`:
/// `{project_id, prompt, command?, model?, effort?, base_branch?,
/// workspace_name?, branch_name?}`.
public struct SupermuxAgentStartRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String
    /// The task Claude starts on.
    public let prompt: String
    /// The Claude command to run; absent means the Mac's selection.
    public let command: String?
    /// A `--model` selector; absent means the CLI default.
    public let model: String?
    /// An `--effort` level; absent means the CLI default.
    public let effort: String?
    /// The branch to start from; absent uses the project default / `HEAD`.
    public let baseBranch: String?
    /// A typed workspace title; absent means "derive from the prompt".
    public let workspaceName: String?
    /// A typed branch; absent means "derive from the prompt".
    public let branchName: String?

    /// Creates the request.
    public init(
        projectID: String,
        prompt: String,
        command: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        baseBranch: String? = nil,
        workspaceName: String? = nil,
        branchName: String? = nil
    ) {
        self.projectID = projectID
        self.prompt = prompt
        self.command = command
        self.model = model
        self.effort = effort
        self.baseBranch = baseBranch
        self.workspaceName = workspaceName
        self.branchName = branchName
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.agentStart.rawValue }

    /// The exact wire params (optionals omitted when absent).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["project_id": projectID, "prompt": prompt]
        if let command { params["command"] = command }
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        if let baseBranch { params["base_branch"] = baseBranch }
        if let workspaceName { params["workspace_name"] = workspaceName }
        if let branchName { params["branch_name"] = branchName }
        return params
    }
}

/// CLI control request subtypes handled by the harness.
public enum SupermuxHarnessIncomingControlRequestSubtype: String, Sendable {
    /// Requests a user decision before a tool may run.
    case canUseTool = "can_use_tool"
}

/// A CLI-issued `can_use_tool` request.
public struct SupermuxHarnessPermissionRequest: Sendable, Equatable {
    /// The request identifier echoed in the eventual response.
    public let requestID: String
    /// The Claude Code tool name.
    public let toolName: String?
    /// The display name supplied by the CLI.
    public let displayName: String?
    /// The requested tool input.
    public let input: SupermuxHarnessJSONObject?
    /// The preferred permission-card headline.
    public let title: String?
    /// The request description.
    public let requestDescription: String?
    /// Suggested persistent or session permission changes.
    public let permissionSuggestions: [SupermuxHarnessJSONObject]
    /// The path that caused a permission boundary, when supplied.
    public let blockedPath: String?
    /// The CLI decision explanation, when supplied.
    public let decisionReason: String?
    /// Whether the UI must suppress its always-allow affordance.
    public let suppressAlwaysAllowRule: Bool
    /// The tool-use identifier associated with the request.
    public let toolUseID: String?
    /// The subagent identifier associated with the request.
    public let agentID: String?
    /// The complete raw control-request frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a pending permission request.
    ///
    /// - Parameters:
    ///   - requestID: The echoed request identifier.
    ///   - toolName: The optional tool name.
    ///   - displayName: The optional display name.
    ///   - input: The optional tool input.
    ///   - title: The optional preferred headline.
    ///   - requestDescription: The optional request description.
    ///   - permissionSuggestions: Suggested permission changes.
    ///   - blockedPath: The optional blocked path.
    ///   - decisionReason: The optional decision explanation.
    ///   - suppressAlwaysAllowRule: Whether always-allow must be hidden.
    ///   - toolUseID: The optional tool-use identifier.
    ///   - agentID: The optional subagent identifier.
    ///   - rawObject: The complete raw frame.
    public init(
        requestID: String,
        toolName: String?,
        displayName: String?,
        input: SupermuxHarnessJSONObject?,
        title: String?,
        requestDescription: String?,
        permissionSuggestions: [SupermuxHarnessJSONObject],
        blockedPath: String?,
        decisionReason: String?,
        suppressAlwaysAllowRule: Bool,
        toolUseID: String?,
        agentID: String?,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.requestID = requestID
        self.toolName = toolName
        self.displayName = displayName
        self.input = input
        self.title = title
        self.requestDescription = requestDescription
        self.permissionSuggestions = permissionSuggestions
        self.blockedPath = blockedPath
        self.decisionReason = decisionReason
        self.suppressAlwaysAllowRule = suppressAlwaysAllowRule
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.rawObject = rawObject
    }
}

/// A recognized CLI-issued control request.
public struct SupermuxHarnessControlRequestFrame: Sendable {
    /// The request subtype.
    public let subtype: SupermuxHarnessIncomingControlRequestSubtype
    /// The request identifier.
    public let requestID: String
    /// The parsed permission request for `can_use_tool`.
    public let permissionRequest: SupermuxHarnessPermissionRequest
    /// The complete raw frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a CLI-issued control request frame.
    ///
    /// - Parameters:
    ///   - subtype: The recognized request subtype.
    ///   - requestID: The request identifier.
    ///   - permissionRequest: The parsed permission request.
    ///   - rawObject: The complete raw frame.
    public init(
        subtype: SupermuxHarnessIncomingControlRequestSubtype,
        requestID: String,
        permissionRequest: SupermuxHarnessPermissionRequest,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.subtype = subtype
        self.requestID = requestID
        self.permissionRequest = permissionRequest
        self.rawObject = rawObject
    }
}

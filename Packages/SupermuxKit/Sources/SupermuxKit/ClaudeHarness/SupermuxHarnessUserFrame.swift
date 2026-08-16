/// A user echo or tool-result feedback frame.
public struct SupermuxHarnessUserFrame: Sendable {
    /// The nested user message.
    public let message: SupermuxHarnessJSONObject
    /// Structured tool output, preferred over rendered string content when present.
    public let toolUseResult: SupermuxHarnessJSONObject?
    /// The session identifier when supplied by the CLI.
    public let sessionID: String?
    /// The parent tool-use identifier for subagent attribution.
    public let parentToolUseID: String?
    /// The wrapper UUID.
    public let uuid: String?
    /// The complete raw frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a user frame.
    ///
    /// - Parameters:
    ///   - message: The nested user message.
    ///   - toolUseResult: Optional structured tool output.
    ///   - sessionID: The optional session identifier.
    ///   - parentToolUseID: The optional parent tool-use identifier.
    ///   - uuid: The optional wrapper UUID.
    ///   - rawObject: The complete raw frame.
    public init(
        message: SupermuxHarnessJSONObject,
        toolUseResult: SupermuxHarnessJSONObject?,
        sessionID: String?,
        parentToolUseID: String?,
        uuid: String?,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.message = message
        self.toolUseResult = toolUseResult
        self.sessionID = sessionID
        self.parentToolUseID = parentToolUseID
        self.uuid = uuid
        self.rawObject = rawObject
    }
}

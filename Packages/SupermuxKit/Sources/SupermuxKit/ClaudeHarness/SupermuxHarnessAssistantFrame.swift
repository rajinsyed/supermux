/// A completed assistant content-block frame.
public struct SupermuxHarnessAssistantFrame: Sendable {
    /// The complete Anthropic message object.
    public let message: SupermuxHarnessJSONObject
    /// The session identifier when supplied by the CLI.
    public let sessionID: String?
    /// The parent tool-use identifier for subagent attribution.
    public let parentToolUseID: String?
    /// The wrapper UUID used for deduplication.
    public let uuid: String?
    /// The complete raw frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates an assistant frame.
    ///
    /// - Parameters:
    ///   - message: The nested message.
    ///   - sessionID: The optional session identifier.
    ///   - parentToolUseID: The optional parent tool-use identifier.
    ///   - uuid: The optional wrapper UUID.
    ///   - rawObject: The complete raw frame.
    public init(
        message: SupermuxHarnessJSONObject,
        sessionID: String?,
        parentToolUseID: String?,
        uuid: String?,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.message = message
        self.sessionID = sessionID
        self.parentToolUseID = parentToolUseID
        self.uuid = uuid
        self.rawObject = rawObject
    }
}

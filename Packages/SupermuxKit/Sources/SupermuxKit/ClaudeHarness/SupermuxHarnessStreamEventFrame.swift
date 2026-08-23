/// Wrapped Anthropic stream event types handled by the harness.
public enum SupermuxHarnessStreamEventType: String, CaseIterable, Sendable {
    /// The assistant message began.
    case messageStart = "message_start"
    /// A thinking, text, or tool-use block began.
    case contentBlockStart = "content_block_start"
    /// A content block emitted an incremental delta.
    case contentBlockDelta = "content_block_delta"
    /// A content block ended.
    case contentBlockStop = "content_block_stop"
    /// Message stop-reason or usage metadata changed.
    case messageDelta = "message_delta"
    /// The assistant message ended.
    case messageStop = "message_stop"
}

/// A recognized wrapped Anthropic stream event.
public struct SupermuxHarnessStreamEventFrame: Sendable {
    /// The recognized event type.
    public let eventType: SupermuxHarnessStreamEventType
    /// The raw nested Anthropic event.
    public let event: SupermuxHarnessJSONObject
    /// The session identifier when supplied by the CLI.
    public let sessionID: String?
    /// The parent tool-use identifier for subagent attribution.
    public let parentToolUseID: String?
    /// The complete raw wrapper frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a wrapped stream event.
    ///
    /// - Parameters:
    ///   - eventType: The recognized nested event type.
    ///   - event: The complete nested event.
    ///   - sessionID: The optional session identifier.
    ///   - parentToolUseID: The optional parent tool-use identifier.
    ///   - rawObject: The complete raw wrapper.
    public init(
        eventType: SupermuxHarnessStreamEventType,
        event: SupermuxHarnessJSONObject,
        sessionID: String?,
        parentToolUseID: String?,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.eventType = eventType
        self.event = event
        self.sessionID = sessionID
        self.parentToolUseID = parentToolUseID
        self.rawObject = rawObject
    }
}

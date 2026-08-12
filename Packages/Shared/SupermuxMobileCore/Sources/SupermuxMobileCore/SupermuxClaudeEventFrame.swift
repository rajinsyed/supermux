/// Monotonic payload carried by the `supermux.claude.event` topic.
///
/// A client that observes a gap in ``eventNo`` refetches history before
/// applying later frames.
public struct SupermuxClaudeEventFrame: Codable, Sendable, Equatable {
    /// Stable harness session identifier.
    public var sessionID: String
    /// Monotonic event number scoped to the session.
    public var eventNo: UInt64
    /// Compact transcript event payload.
    public var frame: SupermuxClaudeChatEvent

    /// Creates an event-stream frame.
    /// - Parameters:
    ///   - sessionID: Stable harness session identifier.
    ///   - eventNo: Monotonic session-scoped event number.
    ///   - frame: Compact transcript event payload.
    public init(sessionID: String, eventNo: UInt64, frame: SupermuxClaudeChatEvent) {
        self.sessionID = sessionID
        self.eventNo = eventNo
        self.frame = frame
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case eventNo = "event_no"
        case frame
    }
}

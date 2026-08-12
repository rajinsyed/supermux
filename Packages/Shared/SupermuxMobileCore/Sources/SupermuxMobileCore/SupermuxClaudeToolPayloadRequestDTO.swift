/// Parameters for one chunk of `mobile.supermux.claude.tool_payload`.
public struct SupermuxClaudeToolPayloadRequestDTO: Codable, Sendable, Equatable {
    /// Session that owns the transcript message.
    public var sessionID: String
    /// Message whose full tool output or diff should be read.
    public var messageID: String
    /// Raw byte offset to begin reading; omission starts at zero.
    public var offset: Int64?

    /// Creates a tool-payload chunk request.
    /// - Parameters:
    ///   - sessionID: Stable harness session identifier.
    ///   - messageID: Stable transcript message identifier.
    ///   - offset: Optional raw byte offset; `nil` starts at zero.
    public init(sessionID: String, messageID: String, offset: Int64? = nil) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case messageID = "message_id"
        case offset
    }
}

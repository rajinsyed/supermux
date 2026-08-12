/// Parameters for `mobile.supermux.claude.send`.
public struct SupermuxClaudeSendRequestDTO: Codable, Sendable, Equatable {
    /// Session that should receive the prompt.
    public var sessionID: String
    /// Prompt text or slash command.
    public var text: String
    /// Image attachments submitted with the prompt.
    public var attachments: [SupermuxClaudeAttachmentDTO]?

    /// Creates a prompt submission.
    /// - Parameters:
    ///   - sessionID: Stable harness session identifier.
    ///   - text: Prompt text or slash command.
    ///   - attachments: Optional image attachments.
    public init(
        sessionID: String,
        text: String,
        attachments: [SupermuxClaudeAttachmentDTO]? = nil
    ) {
        self.sessionID = sessionID
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case text
        case attachments
    }
}

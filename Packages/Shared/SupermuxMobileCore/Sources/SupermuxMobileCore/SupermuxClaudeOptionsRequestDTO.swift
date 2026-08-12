/// Parameters for `mobile.supermux.claude.options`.
public struct SupermuxClaudeOptionsRequestDTO: Codable, Sendable, Equatable {
    /// Optional session used to request model-specific current options.
    public var sessionID: String?

    /// Creates an options request.
    /// - Parameter sessionID: Optional stable harness session identifier.
    public init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

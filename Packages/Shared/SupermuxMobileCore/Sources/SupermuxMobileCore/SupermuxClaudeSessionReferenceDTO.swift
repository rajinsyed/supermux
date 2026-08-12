/// Parameters that identify one Claude harness session.
public struct SupermuxClaudeSessionReferenceDTO: Codable, Sendable, Equatable {
    /// Stable harness session identifier.
    public var sessionID: String

    /// Creates session-reference parameters.
    /// - Parameter sessionID: Stable harness session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

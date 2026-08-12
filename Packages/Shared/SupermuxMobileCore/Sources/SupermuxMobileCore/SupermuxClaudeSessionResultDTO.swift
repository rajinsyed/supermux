/// Result envelope for create, get, and resume session operations.
public struct SupermuxClaudeSessionResultDTO: Codable, Sendable, Equatable {
    /// The authoritative session snapshot.
    public var session: SupermuxClaudeSessionDTO
    /// Redacted startup stderr when the returned session is failed.
    public var stderrExcerpt: String?

    /// Creates a single-session result.
    /// - Parameters:
    ///   - session: The authoritative session snapshot.
    ///   - stderrExcerpt: Optional redacted startup diagnostic.
    public init(session: SupermuxClaudeSessionDTO, stderrExcerpt: String? = nil) {
        self.session = session
        self.stderrExcerpt = stderrExcerpt
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case stderrExcerpt = "stderr_excerpt"
    }
}

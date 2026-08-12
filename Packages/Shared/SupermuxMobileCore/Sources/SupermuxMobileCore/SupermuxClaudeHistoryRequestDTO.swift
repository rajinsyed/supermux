/// Parameters for `mobile.supermux.claude.history`.
public struct SupermuxClaudeHistoryRequestDTO: Codable, Sendable, Equatable {
    /// Session whose transcript should be read.
    public var sessionID: String
    /// Exclusive sequence cursor; `nil` requests the newest page.
    public var beforeSeq: UInt64?
    /// Maximum messages requested from the Mac.
    public var limit: Int

    /// Creates a history-page request.
    /// - Parameters:
    ///   - sessionID: Stable harness session identifier.
    ///   - beforeSeq: Exclusive sequence cursor, or `nil` for the newest page.
    ///   - limit: Maximum number of messages to return.
    public init(sessionID: String, beforeSeq: UInt64? = nil, limit: Int) {
        self.sessionID = sessionID
        self.beforeSeq = beforeSeq
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case beforeSeq = "before_seq"
        case limit
    }
}

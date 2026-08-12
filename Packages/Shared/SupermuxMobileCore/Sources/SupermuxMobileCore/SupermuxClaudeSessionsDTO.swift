/// Result of `mobile.supermux.claude.sessions.list`.
public struct SupermuxClaudeSessionsDTO: Codable, Sendable, Equatable {
    /// Every retained harness session.
    public var sessions: [SupermuxClaudeSessionDTO]
    /// Monotonic registry revision for payload-light list invalidations.
    public var stateVersion: UInt64

    /// Creates a session-list snapshot.
    /// - Parameters:
    ///   - sessions: Every retained harness session.
    ///   - stateVersion: Monotonic registry revision.
    public init(sessions: [SupermuxClaudeSessionDTO], stateVersion: UInt64) {
        self.sessions = sessions
        self.stateVersion = stateVersion
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
        case stateVersion = "state_version"
    }
}

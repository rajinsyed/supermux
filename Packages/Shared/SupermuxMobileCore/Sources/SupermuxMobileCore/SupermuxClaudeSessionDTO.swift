/// Authoritative mobile snapshot of one Mac-hosted Claude harness session.
///
/// ``version`` is monotonic within the session. Clients replace their local
/// snapshot only with a newer version or an authoritative list/get reply.
public struct SupermuxClaudeSessionDTO: Codable, Sendable, Equatable, Identifiable {
    /// Stable harness-owned session identifier.
    public var sessionID: String
    /// Claude Code's resumable session identifier, once known.
    public var claudeSessionID: String?
    /// Human-readable session title.
    public var title: String
    /// Absolute working directory on the Mac.
    public var cwd: String
    /// Associated Supermux project, when any.
    public var projectID: String?
    /// Launcher that new turns and resume must continue using.
    public var launcher: SupermuxClaudeLauncher
    /// Current model value accepted by Claude Code.
    public var model: String?
    /// Current effort level, when supported by the selected model.
    public var effort: String?
    /// Whether fast mode is enabled.
    public var fastMode: Bool
    /// Maximum thinking-token setting, when configured.
    public var thinkingBudget: Int?
    /// Current mobile-visible lifecycle state.
    public var state: SupermuxClaudeSessionState
    /// Cumulative cost and timing totals.
    public var cost: SupermuxClaudeCostDTO
    /// Number of prompts waiting in the Mac-side queue.
    public var queuedCount: Int
    /// Most recent activity time as Unix seconds.
    public var lastActivityAt: Double?
    /// Monotonic per-session revision.
    public var version: UInt64

    /// The stable identifier used by list and navigation surfaces.
    public var id: String { sessionID }

    /// Creates a session snapshot.
    /// - Parameters:
    ///   - sessionID: Stable harness session identifier.
    ///   - claudeSessionID: Claude Code resume identifier.
    ///   - title: Human-readable title.
    ///   - cwd: Absolute working directory.
    ///   - projectID: Associated Supermux project.
    ///   - launcher: Persisted launcher identity.
    ///   - model: Current Claude model value.
    ///   - effort: Current effort level.
    ///   - fastMode: Whether fast mode is enabled.
    ///   - thinkingBudget: Configured thinking-token maximum.
    ///   - state: Current lifecycle state.
    ///   - cost: Cumulative cost and timing totals.
    ///   - queuedCount: Number of queued prompts.
    ///   - lastActivityAt: Activity time as Unix seconds.
    ///   - version: Monotonic session revision.
    public init(
        sessionID: String,
        claudeSessionID: String? = nil,
        title: String,
        cwd: String,
        projectID: String? = nil,
        launcher: SupermuxClaudeLauncher,
        model: String? = nil,
        effort: String? = nil,
        fastMode: Bool = false,
        thinkingBudget: Int? = nil,
        state: SupermuxClaudeSessionState,
        cost: SupermuxClaudeCostDTO,
        queuedCount: Int = 0,
        lastActivityAt: Double? = nil,
        version: UInt64
    ) {
        self.sessionID = sessionID
        self.claudeSessionID = claudeSessionID
        self.title = title
        self.cwd = cwd
        self.projectID = projectID
        self.launcher = launcher
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.thinkingBudget = thinkingBudget
        self.state = state
        self.cost = cost
        self.queuedCount = queuedCount
        self.lastActivityAt = lastActivityAt
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case claudeSessionID = "claude_session_id"
        case title
        case cwd
        case projectID = "project_id"
        case launcher
        case model
        case effort
        case fastMode = "fast_mode"
        case thinkingBudget = "thinking_budget"
        case state
        case cost
        case queuedCount = "queued_count"
        case lastActivityAt = "last_activity_at"
        case version
    }
}

/// One compact, history-pageable Claude harness chat message.
public struct SupermuxClaudeChatMessageDTO: Codable, Sendable, Equatable, Identifiable {
    /// Stable message or content-block identifier.
    public var id: String
    /// Monotonic transcript sequence used by history pagination.
    public var seq: UInt64
    /// Author of the message.
    public var role: SupermuxClaudeChatRole
    /// Creation or most recent update time as Unix seconds.
    public var timestamp: Double
    /// Presentation kind of the message.
    public var kind: SupermuxClaudeChatMessageKind
    /// Bounded text for prose, thought, or status messages.
    public var text: String?
    /// Bounded tool summary for tool messages.
    public var tool: SupermuxClaudeToolDTO?

    /// Creates a compact chat message.
    /// - Parameters:
    ///   - id: Stable message identifier.
    ///   - seq: Monotonic transcript sequence.
    ///   - role: Message author.
    ///   - timestamp: Unix-second timestamp.
    ///   - kind: Presentation kind.
    ///   - text: Bounded text payload.
    ///   - tool: Bounded tool payload.
    public init(
        id: String,
        seq: UInt64,
        role: SupermuxClaudeChatRole,
        timestamp: Double,
        kind: SupermuxClaudeChatMessageKind,
        text: String? = nil,
        tool: SupermuxClaudeToolDTO? = nil
    ) {
        self.id = id
        self.seq = seq
        self.role = role
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.tool = tool
    }
}

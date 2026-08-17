/// Optional metadata stored beside a Claude subagent transcript.
public struct SupermuxHarnessSubagentTranscriptMetadata: Equatable, Sendable {
    /// The Claude agent type, such as `general-purpose`.
    public let agentType: String?
    /// The task description shown for the agent.
    public let description: String?
    /// The nesting depth at which the agent was spawned.
    public let spawnDepth: Int?

    /// Creates subagent transcript metadata.
    ///
    /// - Parameters:
    ///   - agentType: The optional Claude agent type.
    ///   - description: The optional task description.
    ///   - spawnDepth: The optional nonnegative nesting depth.
    public init(agentType: String?, description: String?, spawnDepth: Int?) {
        self.agentType = agentType
        self.description = description
        self.spawnDepth = spawnDepth
    }
}

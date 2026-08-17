/// A bounded replay page loaded from a Claude subagent transcript.
public struct SupermuxHarnessSubagentTranscriptPage: Equatable, Sendable {
    /// Replayable protocol-shaped user and assistant events.
    public let events: [SupermuxHarnessJSONObject]
    /// Whether older replayable events were omitted to enforce the byte limit.
    public let truncated: Bool
    /// Whether no transcript file currently exists at the expected safe location.
    public let missing: Bool
    /// Optional metadata loaded from the sibling `.meta.json` file.
    public let metadata: SupermuxHarnessSubagentTranscriptMetadata?

    /// Creates a bounded subagent transcript page.
    ///
    /// - Parameters:
    ///   - events: Protocol-shaped replay events.
    ///   - truncated: Whether older replayable events were omitted.
    ///   - missing: Whether the transcript file is absent.
    ///   - metadata: Optional sibling metadata.
    public init(
        events: [SupermuxHarnessJSONObject],
        truncated: Bool,
        missing: Bool,
        metadata: SupermuxHarnessSubagentTranscriptMetadata?
    ) {
        self.events = events
        self.truncated = truncated
        self.missing = missing
        self.metadata = metadata
    }
}

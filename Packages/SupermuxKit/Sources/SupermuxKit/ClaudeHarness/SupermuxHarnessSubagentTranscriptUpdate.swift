/// A bounded replacement or delta loaded from a Claude subagent transcript.
public struct SupermuxHarnessSubagentTranscriptUpdate: Equatable, Sendable {
    /// The monotonically increasing logical revision represented by this update.
    public let revision: Int
    /// Whether the consumer must replace its retained event list before applying this update.
    public let replace: Bool
    /// The number of retained prefix events to discard before appending ``events``.
    public let droppedEventCount: Int
    /// Replayable protocol-shaped user and assistant events.
    public let events: [SupermuxHarnessJSONObject]
    /// Whether older replayable events were omitted to enforce the byte limit.
    public let truncated: Bool
    /// Whether no transcript file currently exists at the expected safe location.
    public let missing: Bool
    /// The metadata mutation accompanying this update.
    public let metadata: SupermuxHarnessSubagentTranscriptMetadataUpdate

    /// Creates a bounded subagent transcript replacement or delta.
    ///
    /// - Parameters:
    ///   - revision: The logical revision represented by the update.
    ///   - replace: Whether retained consumer state must be replaced.
    ///   - droppedEventCount: The retained prefix length to discard before appending events.
    ///   - events: Protocol-shaped replay events to replace or append.
    ///   - truncated: Whether older replayable events were omitted.
    ///   - missing: Whether the transcript file is absent.
    ///   - metadata: The metadata mutation to apply.
    public init(
        revision: Int,
        replace: Bool,
        droppedEventCount: Int,
        events: [SupermuxHarnessJSONObject],
        truncated: Bool,
        missing: Bool,
        metadata: SupermuxHarnessSubagentTranscriptMetadataUpdate
    ) {
        self.revision = revision
        self.replace = replace
        self.droppedEventCount = droppedEventCount
        self.events = events
        self.truncated = truncated
        self.missing = missing
        self.metadata = metadata
    }
}

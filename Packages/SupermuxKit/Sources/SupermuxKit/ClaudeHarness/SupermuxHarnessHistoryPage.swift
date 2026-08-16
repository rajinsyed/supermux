/// A bounded persisted-history replay using live protocol-shaped events.
public struct SupermuxHarnessHistoryPage: Equatable, Sendable {
    /// Main-chain assistant and user frames in root-to-leaf order.
    public let events: [SupermuxHarnessJSONObject]
    /// Whether older events were omitted by the requested record limit.
    public let truncated: Bool

    /// Creates a persisted-history page.
    ///
    /// - Parameters:
    ///   - events: Protocol-shaped replay events.
    ///   - truncated: Whether the page omitted older records.
    public init(events: [SupermuxHarnessJSONObject], truncated: Bool) {
        self.events = events
        self.truncated = truncated
    }
}

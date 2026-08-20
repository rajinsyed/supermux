import Foundation

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

    /// Retains the newest contiguous suffix whose compact JSON fits the byte budget.
    func limitingSerializedEventBytes(_ maximumEventBytes: Int?) throws -> Self {
        guard let maximumEventBytes, !events.isEmpty else { return self }
        let budget = max(0, maximumEventBytes)
        var retainedBytes = 0
        var retainedStart = events.endIndex
        for index in events.indices.reversed() {
            let eventBytes = try JSONSerialization.data(
                withJSONObject: events[index].rawValue
            ).count
            guard eventBytes <= budget - retainedBytes else { break }
            retainedBytes += eventBytes
            retainedStart = index
        }
        guard retainedStart > events.startIndex else { return self }
        let retainedEvents = retainedStart == events.endIndex
            ? []
            : Array(events[retainedStart...])
        return Self(events: retainedEvents, truncated: true)
    }
}

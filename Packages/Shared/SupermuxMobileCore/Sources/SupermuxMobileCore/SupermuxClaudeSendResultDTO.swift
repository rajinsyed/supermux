/// Result of submitting a Claude harness prompt.
public struct SupermuxClaudeSendResultDTO: Codable, Sendable, Equatable {
    /// Whether the prompt entered the queue instead of dispatching immediately.
    public var queued: Bool
    /// One-based queue position when queued.
    public var queuePosition: Int?

    /// Creates a prompt-submission result.
    /// - Parameters:
    ///   - queued: Whether the prompt entered the queue.
    ///   - queuePosition: One-based queue position when queued.
    public init(queued: Bool, queuePosition: Int? = nil) {
        self.queued = queued
        self.queuePosition = queuePosition
    }

    private enum CodingKeys: String, CodingKey {
        case queued
        case queuePosition = "queue_position"
    }
}

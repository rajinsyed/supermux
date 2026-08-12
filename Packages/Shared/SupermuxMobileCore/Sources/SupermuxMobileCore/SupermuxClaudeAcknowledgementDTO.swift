/// Acknowledgement returned by end, delete, and interrupt operations.
public struct SupermuxClaudeAcknowledgementDTO: Codable, Sendable, Equatable {
    /// Whether the Mac accepted the requested operation.
    public var acknowledged: Bool

    /// Creates an operation acknowledgement.
    /// - Parameter acknowledged: Whether the operation was accepted.
    public init(acknowledged: Bool) {
        self.acknowledged = acknowledged
    }
}

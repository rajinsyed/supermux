/// Result of acquiring, renewing, or releasing a Claude event watch lease.
public struct SupermuxClaudeWatchResultDTO: Codable, Sendable, Equatable {
    /// Whether the watcher is enabled after the operation.
    public var enabled: Bool
    /// Lease expiration time as Unix seconds, when enabled.
    public var leaseExpiresAt: Double?

    /// Creates a watcher result.
    /// - Parameters:
    ///   - enabled: Whether the watcher is enabled.
    ///   - leaseExpiresAt: Lease expiration time as Unix seconds.
    public init(enabled: Bool, leaseExpiresAt: Double? = nil) {
        self.enabled = enabled
        self.leaseExpiresAt = leaseExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case leaseExpiresAt = "lease_expires_at"
    }
}

/// Leased watcher parameters for `mobile.supermux.claude.watch`.
public struct SupermuxClaudeWatchRequestDTO: Codable, Sendable, Equatable {
    /// Whether to acquire/renew or release the watch lease.
    public var enable: Bool
    /// Stable phone-client identifier used to scope the lease.
    public var clientID: String

    /// Creates a watcher lease request.
    /// - Parameters:
    ///   - enable: Whether to acquire/renew or release the lease.
    ///   - clientID: Stable phone-client identifier.
    public init(enable: Bool, clientID: String) {
        self.enable = enable
        self.clientID = clientID
    }

    private enum CodingKeys: String, CodingKey {
        case enable
        case clientID = "client_id"
    }
}

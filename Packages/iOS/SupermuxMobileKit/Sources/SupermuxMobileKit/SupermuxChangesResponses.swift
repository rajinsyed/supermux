/// Typed result values for the `mobile.supermux.changes.*` read/stage
/// methods. `changes.status` decodes straight into
/// `SupermuxMobileCore.SupermuxChangesStatusDTO` and `changes.diff` into
/// `SupermuxDiffDTO`; only the watch/ack envelopes need phone-side types.
/// Every field is optional so old peers tolerate additions.

/// Result of `mobile.supermux.changes.watch`: `{watching, ttl_seconds}`.
public struct SupermuxChangesWatchResponse: Codable, Sendable, Equatable {
    /// Whether the Mac is now watching the workspace's repository.
    public var watching: Bool?
    /// The watch lease's TTL in seconds (120 today); the phone heartbeats
    /// well inside it.
    public var ttlSeconds: Int?

    /// Creates the response (used by tests and fakes).
    /// - Parameters:
    ///   - watching: Optional watching flag.
    ///   - ttlSeconds: Optional lease TTL in seconds.
    public init(watching: Bool? = nil, ttlSeconds: Int? = nil) {
        self.watching = watching
        self.ttlSeconds = ttlSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case watching
        case ttlSeconds = "ttl_seconds"
    }
}

/// Result of `mobile.supermux.changes.stage`/`unstage`/`discard`: `{ok}`.
public struct SupermuxChangesAckResponse: Codable, Sendable, Equatable {
    /// Whether the mutation applied.
    public var ok: Bool?

    /// Creates the response (used by tests and fakes).
    /// - Parameter ok: Optional success flag.
    public init(ok: Bool? = nil) {
        self.ok = ok
    }
}

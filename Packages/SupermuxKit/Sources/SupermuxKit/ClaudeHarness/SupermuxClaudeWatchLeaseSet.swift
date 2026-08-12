public import Foundation

/// Value-typed holder set for the leased Claude mobile event subscription.
public struct SupermuxClaudeWatchLeaseSet: Sendable, Equatable {
    /// Default lease duration used by the Mac host.
    public static let defaultTTL: TimeInterval = 120

    private var expirations: [String: Date] = [:]

    /// Creates an empty holder set.
    public init() {}

    /// Whether at least one unexpired holder remains after the latest sweep.
    public var isActive: Bool { !expirations.isEmpty }

    /// Acquires or renews one client holder and returns its expiration.
    /// - Parameters:
    ///   - clientID: Stable client identifier.
    ///   - now: Renewal time supplied by the host clock.
    ///   - ttl: Lease duration; defaults to ``defaultTTL``.
    /// - Returns: The new expiration time.
    @discardableResult
    public mutating func renew(
        clientID: String,
        now: Date,
        ttl: TimeInterval = Self.defaultTTL
    ) -> Date {
        let expiration = now.addingTimeInterval(ttl)
        expirations[clientID] = expiration
        return expiration
    }

    /// Releases one holder without affecting other clients.
    /// - Parameter clientID: Stable client identifier to release.
    public mutating func release(clientID: String) {
        expirations.removeValue(forKey: clientID)
    }

    /// Removes holders whose expiration is at or before the reference time.
    /// - Parameter now: Reference time supplied by the host clock.
    public mutating func sweep(now: Date) {
        expirations = expirations.filter { $0.value > now }
    }
}

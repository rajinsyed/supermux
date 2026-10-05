public import Foundation

/// When a device link dials the other Mac again: the waits between dials.
///
/// Today's rules, as `DeviceLinkReconnectPolicy` applies them: a fixed table
/// that stops at 30 s, no spread.
public enum SupermuxDeviceLinkBackoff {
    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    /// The longest wait between two dials.
    public static var cap: Duration { delays[delays.count - 1] }

    /// The wait before the next dial after `failures` consecutive failures.
    public static func delay(afterFailures failures: Int) -> Duration {
        delays[min(max(failures - 1, 0), delays.count - 1)]
    }

    /// `delay` spread by a uniform draw `unit` in 0…1.
    public static func jittered(_ delay: Duration, unit: Double) -> Duration {
        delay
    }

    /// `delay` spread by a random draw.
    public static func jittered(_ delay: Duration) -> Duration {
        jittered(delay, unit: Double.random(in: 0...1))
    }
}

/// What one connected session of a device link proved before it ended.
///
/// Today's rule: a session that stayed up 30 s is stable and its loss
/// redials at once, whatever it carried and however it ended.
public struct SupermuxDeviceLinkSession: Equatable, Sendable {
    public enum Redial: Equatable, Sendable {
        /// Dial again at once, from the first attempt.
        case now
        /// Wait `delay`, then dial attempt `attempt + 1`.
        case after(attempt: Int, delay: Duration)
    }

    /// How long a session must stay up to count as stable.
    public static let provenLifetime: TimeInterval = 30

    public let connectedAt: Date
    /// The dial attempt that opened this session.
    public let attempt: Int
    public private(set) var exchanged = false

    public init(connectedAt: Date, attempt: Int) {
        self.connectedAt = connectedAt
        self.attempt = attempt
    }

    /// A request beyond the dial's handshake was answered on this session.
    public mutating func noteExchange() {
        exchanged = true
    }

    public func provedHealthy(endedAt: Date) -> Bool {
        endedAt.timeIntervalSince(connectedAt) >= Self.provenLifetime
    }

    /// What the link does once this session ended.
    public func redial(endedAt: Date, unresponsive: Bool) -> Redial {
        if provedHealthy(endedAt: endedAt) { return .now }
        return .after(attempt: attempt, delay: SupermuxDeviceLinkBackoff.delay(afterFailures: attempt))
    }
}

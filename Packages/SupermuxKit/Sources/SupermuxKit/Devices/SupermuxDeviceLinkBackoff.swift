public import Foundation

/// When a device link dials the other Mac again: the waits between dials.
///
/// Each consecutive failure doubles the wait, from 1 s up to 2 min. The old
/// table stopped at 30 s, so a Mac asleep with its lid closed was dialed every
/// 40 s all night (a 10 s dial, then 30 s), and dials that reach it through its
/// relay connection can wake it. The cap bounds how long a Mac that comes back
/// waits for this one to notice.
public enum SupermuxDeviceLinkBackoff {
    public static let base: Duration = .seconds(1)
    public static let cap: Duration = .seconds(120)
    /// Each wait is spread by up to this fraction either way, so links that
    /// failed together (one Mac's mirrors, several Macs after a network
    /// change) do not dial in step.
    public static let jitterFraction = 0.2
    /// How long a link waits between leaving its session for a better path
    /// (a planned redial: the route switcher moving it to the direct lane)
    /// and dialing again, so the old session has released its slot.
    public static let plannedRedialSettle: Duration = .milliseconds(300)

    /// The wait before the next dial after `failures` consecutive failures.
    public static func delay(afterFailures failures: Int) -> Duration {
        // 2^7 s already passes the cap; the bound keeps a long streak from overflowing.
        let doublings = min(max(failures - 1, 0), 8)
        return min(base * (1 << doublings), cap)
    }

    /// `delay` spread by `unit`, a uniform draw in 0…1 (0 is 20 % shorter,
    /// 1 is 20 % longer), to the millisecond.
    public static func jittered(_ delay: Duration, unit: Double) -> Duration {
        let factor = 1 + jitterFraction * (2 * min(max(unit, 0), 1) - 1)
        let milliseconds = Double(delay.components.seconds) * 1_000
            + Double(delay.components.attoseconds) / 1_000_000_000_000_000
        return .milliseconds(Int64((milliseconds * factor).rounded()))
    }

    /// `delay` spread by a random draw.
    public static func jittered(_ delay: Duration) -> Duration {
        jittered(delay, unit: Double.random(in: 0...1))
    }
}

/// What one connected session of a device link proved before it ended, and so
/// when the link dials again.
///
/// A session proves the other Mac healthy by answering a request beyond the
/// dial's handshake and staying up for ``provenLifetime``. Lifetime alone
/// proved nothing in the field: on a congested relay every session lived about
/// 31 s (a 20 s reply deadline, then a 10 s probe), just past the old 30 s bar,
/// so every loss redialed at once, and sessions made inside a lid-closed
/// laptop's DarkWakes (up to 35 s, then QUIC's 30 s idle timeout) did the same.
public struct SupermuxDeviceLinkSession: Equatable, Sendable {
    public enum Redial: Equatable, Sendable {
        /// Dial again at once, from the first attempt.
        case now
        /// Wait `delay`, then dial attempt `attempt + 1`.
        case after(attempt: Int, delay: Duration)
    }

    /// How long a session that answered requests must stay up to prove the
    /// other Mac healthy: past a DarkWake plus QUIC's idle timeout (about
    /// 65 s) and past a missed deadline plus the liveness check.
    public static let provenLifetime: TimeInterval = 120

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
        exchanged && endedAt.timeIntervalSince(connectedAt) >= Self.provenLifetime
    }

    /// What the link does once this session ended. `unresponsive`: it ended
    /// because the other Mac stopped answering (a missed reply deadline, then
    /// no sign of life), so it is never dialed again at once.
    ///
    /// A healthy session ends any failure streak: the other Mac closed it (a
    /// restart of its app, a network change) and is dialed again at once, or
    /// it went silent and the backoff starts from its first step. A session
    /// that proved nothing continues the streak of the dial that opened it.
    public func redial(endedAt: Date, unresponsive: Bool) -> Redial {
        guard provedHealthy(endedAt: endedAt) else { return Self.backOff(failures: max(attempt, 1)) }
        return unresponsive ? Self.backOff(failures: 1) : .now
    }

    private static func backOff(failures: Int) -> Redial {
        .after(attempt: failures, delay: SupermuxDeviceLinkBackoff.delay(afterFailures: failures))
    }
}

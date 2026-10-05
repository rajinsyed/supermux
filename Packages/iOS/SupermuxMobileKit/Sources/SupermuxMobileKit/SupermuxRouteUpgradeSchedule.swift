public import Foundation

/// When the phone probes a Mac's direct lane while its session rides a
/// relay, and when a probe that worked moves the session there.
///
/// One per Mac. A probe is one direct handshake that is never admitted
/// (``SupermuxDialRace`` with no fallback). The move is one planned redial,
/// whose dial race then lands on the direct lane. Probes run every
/// ``probeInterval`` (±``jitterFraction``) while the session is relayed and
/// the Mac's direct addresses are known, slowing to ``slowProbeInterval``
/// after ``failuresBeforeSlowing`` misses in a row. A network change or new
/// addresses probe at once. At most one move per ``switchHold``, and none
/// for ``switchHold`` after a direct session fell back to the relay, unless
/// the network changed since.
public struct SupermuxRouteUpgradeSchedule: Equatable, Sendable {
    /// The time between probes.
    public static let probeInterval: TimeInterval = 10
    /// The time between probes after repeated misses.
    public static let slowProbeInterval: TimeInterval = 30
    /// Misses in a row before probes slow down.
    public static let failuresBeforeSlowing = 5
    /// The least time between two moves, and after a fallback.
    public static let switchHold: TimeInterval = 30
    /// The spread applied to each probe interval.
    public static let jitterFraction = 0.2

    /// When the next probe may run; nil means now.
    public private(set) var nextProbeAt: Date?
    /// Whether a probe is in flight.
    public private(set) var isProbing = false
    /// Probes missed in a row.
    public private(set) var consecutiveFailures = 0
    /// When a probe last moved the session.
    public private(set) var lastSwitchAt: Date?
    /// When a direct session last fell back to the relay.
    public private(set) var lastFallbackAt: Date?
    private var lastAdmittedDirect: Bool?

    /// A Mac with nothing scheduled.
    public init() {}

    /// Whether to probe now.
    /// - Parameters:
    ///   - onRelay: Whether the session rides a relay right now.
    ///   - hasCandidates: Whether the Mac's direct addresses are known.
    ///   - now: The current time.
    public func probeDue(onRelay: Bool, hasCandidates: Bool, now: Date) -> Bool {
        guard onRelay, hasCandidates, !isProbing else { return false }
        return nextProbeAt.map { now >= $0 } ?? true
    }

    /// A probe started.
    public mutating func probeStarted() {
        isProbing = true
    }

    /// A probe finished.
    /// - Parameters:
    ///   - succeeded: Whether the direct handshake completed.
    ///   - now: The current time.
    ///   - jitter: A number in -1...1 that spreads the next interval.
    /// - Returns: Whether to move the session now (one planned redial).
    public mutating func probeFinished(succeeded: Bool, now: Date, jitter: Double) -> Bool {
        isProbing = false
        guard succeeded else {
            consecutiveFailures += 1
            let interval = consecutiveFailures >= Self.failuresBeforeSlowing ? Self.slowProbeInterval : Self.probeInterval
            let spread = 1 + Self.jitterFraction * min(1, max(-1, jitter))
            nextProbeAt = now.addingTimeInterval(interval * spread)
            return false
        }
        consecutiveFailures = 0
        if let holdEnd, now < holdEnd {
            nextProbeAt = holdEnd
            return false
        }
        lastSwitchAt = now
        nextProbeAt = now.addingTimeInterval(Self.probeInterval)
        return true
    }

    /// The end of the current hold on moves: after the last move, and after
    /// the last fallback.
    private var holdEnd: Date? {
        [lastSwitchAt, lastFallbackAt].compactMap { $0 }.max()?.addingTimeInterval(Self.switchHold)
    }

    /// A session to the Mac was admitted.
    /// - Parameters:
    ///   - direct: Whether it went out on the direct lane.
    ///   - directTried: Whether its dial raced the direct lane (and lost,
    ///     when `direct` is false).
    ///   - now: The current time.
    public mutating func sessionAdmitted(direct: Bool, directTried: Bool, now: Date) {
        if direct {
            consecutiveFailures = 0
            nextProbeAt = nil
        } else {
            if lastAdmittedDirect == true { lastFallbackAt = now }
            // The dial just tried the direct lane and lost: give it one interval.
            if directTried { nextProbeAt = now.addingTimeInterval(Self.probeInterval) }
        }
        lastAdmittedDirect = direct
    }

    /// The phone's network changed: probe at once, at the normal pace.
    public mutating func networkChanged() {
        consecutiveFailures = 0
        nextProbeAt = nil
        lastFallbackAt = nil
    }

    /// The Mac handed over new direct addresses: probe at once.
    public mutating func candidatesChanged() {
        nextProbeAt = nil
    }
}

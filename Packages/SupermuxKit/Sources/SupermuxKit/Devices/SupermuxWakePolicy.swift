public import Foundation

/// What this Mac does about its own sleep, wake and network changes.
///
/// - Between `willSleep` and a full wake the Mac is **dark**. A laptop asleep
///   with its lid closed DarkWakes up to ~165 times an hour for 2–35 s each,
///   with no user and no wake notification; links made then are zombies. While
///   dark, this Mac dials no other Mac. Only a full wake ends it: `didWake`,
///   the screens waking, or (should a notification be lost) a display that is
///   awake.
/// - A full wake recovers the network once: iroh is told the network changed,
///   the direct lane is rebuilt and relayed links probe direct now. After a
///   sleep of at least ``endpointRebuildSleep`` the main endpoint is rebuilt
///   too: by then every QUIC session on it is dead (30 s of idle on the peers'
///   clocks) and its relay socket and per-peer path blocks are stale.
/// - A network change while awake recovers the same way, never rebuilding.
///
/// The sleep is measured on the wall clock: iroh's and Swift's monotonic
/// clocks stop while the Mac sleeps. Pure state; the owner feeds it the
/// system's signals and acts on the ``Recovery`` it returns.
public struct SupermuxWakePolicy: Equatable, Sendable {
    /// What woke the Mac, or changed under it.
    public enum Reason: String, Equatable, Sendable {
        /// `NSWorkspace.didWakeNotification`: macOS posts it for full wakes only.
        case wake
        /// `NSWorkspace.screensDidWakeNotification`.
        case screensWake = "screens-wake"
        /// A display found awake while dark: a wake notification was lost.
        case displayAwake = "display-awake"
        /// The network path changed (interfaces or addresses, Tailscale too).
        case networkChange = "network-change"
    }

    /// One recovery to run.
    public struct Recovery: Equatable, Sendable {
        public let reason: Reason
        /// How long the Mac slept by the wall clock; nil when unknown (no
        /// `willSleep` seen, a clock set backwards) or not after a sleep.
        public let sleptSeconds: Int?
        /// Close the main endpoint and bind a new one.
        public let rebuildsMainEndpoint: Bool

        public init(reason: Reason, sleptSeconds: Int?, rebuildsMainEndpoint: Bool) {
            self.reason = reason
            self.sleptSeconds = sleptSeconds
            self.rebuildsMainEndpoint = rebuildsMainEndpoint
        }
    }

    /// The shortest sleep after which the main endpoint is rebuilt.
    public static let endpointRebuildSleep: TimeInterval = 60
    /// Wake signals this close to the last recovery belong to the same wake.
    public static let wakeDedupWindow: TimeInterval = 10

    /// When `willSleep` came, while the Mac is dark.
    public private(set) var asleepSince: Date?
    private var lastWakeRecoveryAt: Date?

    public init() {}

    /// Whether the Mac is between `willSleep` and a full wake.
    public var isDark: Bool { asleepSince != nil }

    /// The Mac is going to sleep. A second one while dark (back to sleep from
    /// a DarkWake) keeps the first, so a whole night is measured.
    public mutating func willSleep(at now: Date) {
        if asleepSince == nil { asleepSince = now }
    }

    /// A wake signal. A recovery when it ends a sleep, or when a `didWake`
    /// comes with no sleep seen; nil for the other signals of a wake already
    /// recovered and for a screens or display wake without a sleep.
    public mutating func woke(_ reason: Reason, at now: Date) -> Recovery? {
        if let since = asleepSince {
            asleepSince = nil
            lastWakeRecoveryAt = now
            let slept = now.timeIntervalSince(since)
            let measured = slept >= 0 ? Int(slept.rounded(.down)) : nil
            let rebuilds = measured.map { TimeInterval($0) >= Self.endpointRebuildSleep } ?? false
            return Recovery(reason: reason, sleptSeconds: measured, rebuildsMainEndpoint: rebuilds)
        }
        guard reason == .wake else { return nil }
        if let last = lastWakeRecoveryAt, now >= last, now.timeIntervalSince(last) < Self.wakeDedupWindow { return nil }
        lastWakeRecoveryAt = now
        return Recovery(reason: reason, sleptSeconds: nil, rebuildsMainEndpoint: false)
    }

    /// The network path changed. Nil while dark: the full wake recovers.
    /// Bursts are the caller's to debounce.
    public mutating func networkChanged(at now: Date) -> Recovery? {
        guard asleepSince == nil else { return nil }
        return Recovery(reason: .networkChange, sleptSeconds: nil, rebuildsMainEndpoint: false)
    }
}

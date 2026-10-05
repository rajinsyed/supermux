public import Foundation

/// What a link to another Mac does once that Mac said it is going to sleep.
///
/// A Mac about to sleep tells the Macs connected to it. Until it shows it is
/// awake again, each wait before redialing it lasts at least ``wait``: a laptop
/// asleep with its lid closed was dialed every 40 s all night, and its Wi-Fi
/// keepalive offload woke it for many of those dials, each making a ~31 s
/// zombie session. It shows it is awake by dialing this Mac (a woken Mac
/// redials its own links at once, and never dials from a DarkWake), which also
/// dials it back at once, or by a session that started after the notice and
/// stayed up ``provenAwakeLifetime`` (longer than a DarkWake plus QUIC's idle
/// timeout).
///
/// Pure state, one per remote Mac; the owner feeds it the notice, the link's
/// sessions and dial-ins, and stretches the link's waits with ``wait(after:)``.
public struct SupermuxPeerSleep: Equatable, Sendable {
    /// The least wait before redialing a Mac that is asleep.
    public static let wait: Duration = .seconds(300)
    /// A session up this long, started after the notice, proves the Mac awake.
    public static let provenAwakeLifetime: TimeInterval = 120
    /// Dial-ins dial the Mac back at most this often.
    public static let nudgeSpacing: TimeInterval = 15

    /// When the newest notice came, while the Mac counts as asleep.
    public private(set) var asleepSince: Date?
    private var connectedAt: Date?
    private var lastNudgeAt: Date?

    public init() {}

    public var isAsleep: Bool { asleepSince != nil }

    /// The Mac said it is going to sleep.
    public mutating func announced(at now: Date) {
        asleepSince = now
    }

    /// The link's wait before its next dial: `computed`, or ``wait`` while
    /// the Mac is asleep and that is longer.
    public func wait(after computed: Duration) -> Duration {
        isAsleep ? max(computed, Self.wait) : computed
    }

    /// A session of the link started.
    public mutating func connected(at now: Date) {
        connectedAt = now
    }

    /// The session ended. One that started after the notice and stayed up
    /// ``provenAwakeLifetime`` clears it; a DarkWake's never does.
    public mutating func disconnected(at now: Date) {
        defer { connectedAt = nil }
        guard let since = asleepSince, let connectedAt, connectedAt >= since,
              now.timeIntervalSince(connectedAt) >= Self.provenAwakeLifetime else { return }
        asleepSince = nil
    }

    /// The Mac dialed this one: it is awake. Whether to dial it back now (at
    /// most once per ``nudgeSpacing``).
    public mutating func dialedIn(at now: Date) -> Bool {
        asleepSince = nil
        if let last = lastNudgeAt, now >= last, now.timeIntervalSince(last) < Self.nudgeSpacing { return false }
        lastNudgeAt = now
        return true
    }
}

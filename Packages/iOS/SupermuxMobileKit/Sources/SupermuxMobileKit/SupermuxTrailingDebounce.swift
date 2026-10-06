import Foundation

/// Acts once things stop changing: each ``poke(_:)`` restarts the wait, and
/// only the last poke's action runs, ``settle`` after it, but never later
/// than ``maximumWait`` after the first poke of the burst. The phone's
/// network reports a move as a burst of path updates (Wi-Fi drops, cellular
/// comes up, Tailscale reconnects); acting on the first would judge the
/// network halfway through the move and drop what came after. A burst that
/// never pauses for ``settle`` (a flapping Wi-Fi) is acted on at the
/// maximum, and the next poke starts a new burst.
public final class SupermuxTrailingDebounce: @unchecked Sendable {
    /// How long things stay quiet before the action runs.
    public let settle: Duration
    /// The longest a burst waits, from its first poke.
    public let maximumWait: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var pending: Task<Void, Never>?
    /// When the burst being waited out began; nil between bursts.
    private var burstStart: ContinuousClock.Instant?
    /// The latest poke's number: only its action may run.
    private var latest: UInt64 = 0

    /// - Parameters:
    ///   - settle: The quiet time before the action runs.
    ///   - maximumWait: The longest a burst waits, from its first poke.
    ///   - now: The clock (tests replace it).
    ///   - sleep: The timer (tests replace it).
    public init(
        settle: Duration,
        maximumWait: Duration = .seconds(5),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settle = settle
        self.maximumWait = maximumWait
        self.now = now
        self.sleep = sleep
    }

    /// Restarts the wait; `action` runs once nothing pokes for ``settle``
    /// (or ``maximumWait`` after the burst's first poke, whichever is
    /// sooner), in place of every earlier poke's.
    public func poke(_ action: @escaping @Sendable () async -> Void) {
        lock.withLock {
            pending?.cancel()
            latest &+= 1
            let poke = latest
            let time = now()
            let start = burstStart ?? time
            burstStart = start
            let wait = min(settle, max(.zero, maximumWait - start.duration(to: time)))
            pending = Task { [sleep] in
                guard (try? await sleep(wait)) != nil, self.takeTurn(poke) else { return }
                await action()
            }
        }
    }

    /// Drops a pending action.
    public func cancel() {
        lock.withLock {
            pending?.cancel()
            pending = nil
            burstStart = nil
            latest &+= 1
        }
    }

    /// Whether `poke` is still the latest; if so its burst ends here.
    private func takeTurn(_ poke: UInt64) -> Bool {
        lock.withLock {
            guard poke == latest else { return false }
            pending = nil
            burstStart = nil
            return true
        }
    }
}

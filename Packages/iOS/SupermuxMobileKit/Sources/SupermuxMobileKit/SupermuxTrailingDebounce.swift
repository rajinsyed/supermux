import Foundation

/// Acts once things stop changing: each ``poke(_:)`` restarts the wait, and
/// only the last poke's action runs, ``settle`` after it. The phone's
/// network reports a move as a burst of path updates (Wi-Fi drops, cellular
/// comes up, Tailscale reconnects); acting on the first would judge the
/// network halfway through the move and drop what came after.
public final class SupermuxTrailingDebounce: @unchecked Sendable {
    /// How long things stay quiet before the action runs.
    public let settle: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var pending: Task<Void, Never>?

    /// - Parameters:
    ///   - settle: The quiet time before the action runs.
    ///   - sleep: The timer (tests replace it).
    public init(
        settle: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settle = settle
        self.sleep = sleep
    }

    /// Restarts the wait; `action` runs once nothing pokes for ``settle``,
    /// in place of every earlier poke's.
    public func poke(_ action: @escaping @Sendable () async -> Void) {
        lock.withLock {
            pending?.cancel()
            pending = Task { [sleep, settle] in
                guard (try? await sleep(settle)) != nil, !Task.isCancelled else { return }
                await action()
            }
        }
    }

    /// Drops a pending action.
    public func cancel() {
        lock.withLock {
            pending?.cancel()
            pending = nil
        }
    }
}

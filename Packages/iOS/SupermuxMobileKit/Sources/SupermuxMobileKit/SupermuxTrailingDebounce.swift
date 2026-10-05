public import Foundation

/// Acts once things stop changing: each ``poke(_:)`` restarts the wait, and
/// only the last poke's action runs, ``settle`` after it.
///
/// RED STUB: acts on the first poke and drops the pokes that follow within
/// ``settle`` (the old phone's network-change debounce).
public final class SupermuxTrailingDebounce: @unchecked Sendable {
    public let settle: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var lastPoke: ContinuousClock.Instant?

    public init(
        settle: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settle = settle
        self.sleep = sleep
    }

    public func poke(_ action: @escaping @Sendable () async -> Void) {
        let acts = lock.withLock { () -> Bool in
            let now = ContinuousClock.now
            if let lastPoke, lastPoke.duration(to: now) < settle { return false }
            lastPoke = now
            return true
        }
        guard acts else { return }
        Task { await action() }
    }

    public func cancel() {}
}

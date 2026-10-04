import Foundation

/// The one trailing mobile state sync v2 tick the fork's observers share.
///
/// ``SupermuxMobileActivityObserver`` and ``SupermuxMobileSidebarStatusObserver``
/// both tick `MobileStateSyncHost` for changes upstream's
/// `MobileWorkspaceListObserver` cannot see. Each tick rebuilds every row of
/// every window (`buildRows`), so instead of each observer ticking on its own
/// window, both ``request()`` here: every request inside one ``delay``
/// collapses into a single `broadcastIfSubscribed()`, whose diff emits only the
/// rows that changed.
@MainActor
final class SupermuxStateSyncTicker {
    static let shared = SupermuxStateSyncTicker()

    /// How long a request waits for others to join it.
    static let delay: Duration = .milliseconds(150)
    /// Timer slack, so the wakeup can coalesce with others.
    static let tolerance: Duration = .milliseconds(50)

    private let tick: @MainActor () -> Void
    private let hasSubscribers: @MainActor () -> Bool
    /// The scheduled tick; `nil` when idle.
    private var pendingTick: Task<Void, Never>?

    init(
        tick: @escaping @MainActor () -> Void = { MobileStateSyncHost.shared.broadcastIfSubscribed() },
        hasSubscribers: @escaping @MainActor () -> Bool = {
            MobileHostService.hasEventSubscribers(topic: MobileStateSyncHost.deltaTopic)
        }
    ) {
        self.tick = tick
        self.hasSubscribers = hasSubscribers
    }

    /// Schedules the trailing tick unless one is already pending. Nothing is
    /// scheduled while no client subscribes to the delta topic: the tick would
    /// be a no-op, and a client that subscribes later fetches current rows.
    func request() {
        guard pendingTick == nil, hasSubscribers() else { return }
        pendingTick = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.delay, tolerance: Self.tolerance)
            guard let self, !Task.isCancelled else { return }
            self.pendingTick = nil
            self.tick()
        }
    }
}

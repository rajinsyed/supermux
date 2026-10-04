// SUPERMUX:begin irx-admission-unknown-peer-recheck (a phone missing from the Mac's directory triggers one rate-limited refresh — see SUPERMUX-TOUCHPOINTS.md)
import Foundation

/// Rate-limits the directory refreshes that unknown phones trigger, so a
/// stranger minting endpoint IDs cannot make the Mac hammer the backend.
public actor IrxDirectoryRecheckGate {
    private let cooldown: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let refresh: @Sendable () async -> Void
    private var inFlight: Task<Void, Never>?
    private var lastStarted: ContinuousClock.Instant?

    /// Creates a gate.
    /// - Parameters:
    ///   - cooldown: Minimum time between two refreshes.
    ///   - now: Clock seam for tests.
    ///   - refresh: Fetches the directory and applies it to admission.
    public init(
        cooldown: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        refresh: @escaping @Sendable () async -> Void
    ) {
        self.cooldown = cooldown
        self.now = now
        self.refresh = refresh
    }

    /// Refreshes the directory for an unknown phone: joins a refresh already
    /// running, and returns at once during the cooldown after the last one.
    public func recheck() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let started = now()
        if let lastStarted, lastStarted.duration(to: started) < cooldown { return }
        lastStarted = started
        let task = Task { await refresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }
}
// SUPERMUX:end irx-admission-unknown-peer-recheck

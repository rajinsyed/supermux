public import Foundation
import Observation
public import SupermuxMobileCore

/// Main-actor state for the phone's usage tracker: the paired Mac's Claude
/// Code + Codex rate-limit snapshot, refetched on a slow cadence while the
/// entry point is on screen.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected, so the
/// store is unit-testable against a fake. Inert without `supermux.usage.v1` —
/// against an upstream Mac no request is ever issued and the gauge hides.
///
/// **Read-only by design.** The Mac's ``SupermuxUsageModel`` owns polling,
/// its own rate-limit floor, and every cswap mutation; this store only mirrors
/// what that model already holds. `usage.state` therefore never triggers a
/// provider fetch Mac-side, so the phone cannot push the Anthropic/ChatGPT
/// endpoints past the budget the desktop already enforces — no matter how
/// often it asks.
///
/// Lifecycle: the mount runs ``run()`` inside a `.task`, so polling is
/// structured — it stops the moment the entry point leaves the screen.
@MainActor
@Observable
public final class SupermuxMobileUsageStore {
    /// The Mac's latest snapshot, or `nil` before the first success.
    public private(set) var usage: SupermuxUsageStateDTO?

    /// Whether at least one fetch has succeeded.
    public private(set) var hasLoaded = false

    /// Whether a fetch is currently in flight (drives the refresh spinner).
    public private(set) var isRefreshing = false

    /// Human-readable description of the most recent fetch failure, for a
    /// non-blocking error surface. Cleared on the next success.
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    @ObservationIgnored private let pollInterval: Duration
    /// Cancellable poll sleep; injectable for deterministic tests.
    @ObservationIgnored private let idleSleep: (Duration) async -> Void
    /// The fetch currently on the wire, so concurrent callers join it instead
    /// of being dropped or stacking a second request.
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// Whether the phone shows the usage gauge at all: gated on the host
    /// advertising `supermux.usage.v1`.
    public var showsUsage: Bool { capabilities.supportsUsage }

    /// The single most constrained window across both providers — what the
    /// toolbar gauge fills to. `nil` until something is ready.
    public var tightestWindow: SupermuxUsageWindowDTO? {
        usage?.tightestWindow
    }

    /// Creates a usage store.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - pollInterval: Refetch cadence while mounted. Matches the Mac
    ///     model's own 120 s poll — asking faster would only re-serve the
    ///     same cached snapshot.
    ///   - idleSleep: Poll sleep seam; defaults to `Task.sleep`.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        pollInterval: Duration = .seconds(120),
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.capabilities = capabilities
        self.pollInterval = pollInterval
        self.idleSleep = idleSleep
    }

    /// Refetches on the poll cadence until cancelled. A no-op without
    /// `supermux.usage.v1`.
    ///
    /// Unlike the event-driven stores there is no `supermux.usage.updated`
    /// topic: usage moves continuously rather than in discrete transitions, so
    /// a poke per percent change would be pure noise. The Mac's own model
    /// polls at the same cadence, so this stays one refetch behind at worst.
    public func run() async {
        guard capabilities.supportsUsage else { return }
        while !Task.isCancelled {
            await refresh()
            await idleSleep(pollInterval)
        }
    }

    /// Fetches once, JOINING any fetch already in flight rather than issuing
    /// a second round trip.
    ///
    /// Callers overlap constantly: the poll loop, the sheet's presentation
    /// refresh, and pull-to-refresh are three independent entry points. A
    /// concurrent caller must not simply be dropped — pull-to-refresh would
    /// end its spinner having awaited nothing, and a user retrying a failed
    /// fetch would silently get no request at all with the next automatic
    /// attempt up to a poll period away. Awaiting the shared pass instead
    /// means every caller returns against a settled result, with still only
    /// one request on the wire.
    public func refresh() async {
        guard capabilities.supportsUsage else { return }
        if let inFlight {
            await inFlight.value
            return
        }
        // Unstructured on purpose: the pass belongs to the STORE, not to
        // whichever caller happened to start it, so one caller's cancellation
        // (a poll loop stopping, a sheet dismissing) cannot abort the fetch
        // the other callers are awaiting.
        let pass = Task { @MainActor in await self.performRefresh() }
        inFlight = pass
        await pass.value
        inFlight = nil
    }

    /// One fetch. Failures keep the last-good snapshot on screen: a dropped
    /// connection must not blank numbers that were true a minute ago.
    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            usage = try await client.usageState(SupermuxUsageStateRequest())
            hasLoaded = true
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}

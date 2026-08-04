public import Foundation
public import Observation

/// App-wide model behind the sidebar usage tracker: owns the latest Claude and
/// Codex states and refreshes them on a fixed cadence while any sidebar is
/// visible.
///
/// Cadence: one pass every 2 minutes, with a hard floor between passes that
/// popover-open and manual refreshes cannot bypass — so the UI alone can never
/// exceed `3600 / minimumRefreshInterval` passes/hour. The Claude side is
/// nearly free when cswap serves its cache (cswap's TTL is ~3 minutes and it
/// self-throttles against Anthropic's ~28-30 req/rolling-hour budget); the
/// direct fallback adds its own 180s result TTL in
/// ``SupermuxClaudeUsageSource``, bounding the raw endpoint to ≤20 req/hour
/// no matter what the UI does. Codex's endpoint is polled by its own TUI at
/// 60s, so 120s is comfortably polite.
///
/// The model is view-driven exactly like ``SupermuxWorktreePullRequestModel``:
/// the mounted button runs `.task { await model.runPollLoop() }`, so polling
/// stops when no sidebar is mounted and multiple windows share one loop via
/// the `pollLoopOwner` guard.
@MainActor
@Observable
public final class SupermuxUsageModel {
    public private(set) var claude: SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> = .loading
    public private(set) var codex: SupermuxUsageProviderState<SupermuxCodexUsageSnapshot> = .loading
    /// Whether a pass is currently in flight (drives the refresh spinner).
    public private(set) var isRefreshing = false

    @ObservationIgnored private let claudeFetch: @Sendable () async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>
    @ObservationIgnored private let codexFetch: @Sendable () async -> SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>
    @ObservationIgnored private let pollInterval: Duration
    /// Hard floor between passes — applied to EVERY refresh entry point, so
    /// neither the poll loop, popover opens, nor the manual refresh button can
    /// drive more than one pass per floor interval.
    @ObservationIgnored private let minimumRefreshInterval: TimeInterval
    @ObservationIgnored private var lastPassStartedAt: Date?
    /// Identity of the view instance currently driving the poll loop, so
    /// N mounted sidebars run one loop, and the loop migrates when its owner
    /// unmounts.
    @ObservationIgnored private var pollLoopOwner: UUID?

    public init(
        claudeSource: SupermuxClaudeUsageSource = SupermuxClaudeUsageSource(),
        codexSource: SupermuxCodexUsageSource = SupermuxCodexUsageSource(),
        pollInterval: Duration = .seconds(120),
        minimumRefreshInterval: TimeInterval = 30
    ) {
        self.claudeFetch = { await claudeSource.fetch() }
        self.codexFetch = { await codexSource.fetch() }
        self.pollInterval = pollInterval
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    /// Test seam: inject fetch closures directly.
    init(
        claudeFetch: @escaping @Sendable () async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>,
        codexFetch: @escaping @Sendable () async -> SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>,
        pollInterval: Duration = .seconds(120),
        minimumRefreshInterval: TimeInterval = 30
    ) {
        self.claudeFetch = claudeFetch
        self.codexFetch = codexFetch
        self.pollInterval = pollInterval
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    /// The single most constrained window across both providers — what the
    /// footer button's gauge shows. `nil` until something loads.
    public var tightestWindow: SupermuxUsageWindow? {
        var candidates: [SupermuxUsageWindow] = []
        if let active = claude.snapshot?.activeAccount {
            candidates += active.windows
        }
        if let codexSnapshot = codex.snapshot {
            candidates += codexSnapshot.windows
        }
        return candidates.tightest
    }

    /// When the OLDEST data on display was actually measured — the honest
    /// "updated X ago" for the popover footer. A pass that failed and kept
    /// last-good snapshots does NOT advance this (the snapshots keep their
    /// original `fetchedAt`), so stale data never masquerades as fresh.
    public var oldestDisplayedDataAge: Date? {
        let dates = [
            claude.snapshot.map(\.fetchedAt),
            codex.snapshot.map(\.fetchedAt),
        ].compactMap { $0 }
        return dates.min()
    }

    /// Long-running per-view poll loop; safe to call from several mounted
    /// views (only the first becomes the owner, the rest return immediately
    /// and re-candidate when the owner cancels).
    public func runPollLoop() async {
        let me = UUID()
        while !Task.isCancelled {
            if pollLoopOwner == nil { pollLoopOwner = me }
            if pollLoopOwner == me {
                await refresh()
            }
            do {
                try await Task.sleep(for: pollLoopOwner == me ? pollInterval : .seconds(5))
            } catch {
                break
            }
        }
        if pollLoopOwner == me { pollLoopOwner = nil }
    }

    /// One pass over both providers, concurrently. The floor applies here —
    /// to every caller — so repeated popover opens or refresh-button clicks
    /// coalesce into at most one pass per `minimumRefreshInterval`.
    public func refresh() async {
        guard !isRefreshing else { return }
        if let last = lastPassStartedAt, Date().timeIntervalSince(last) < minimumRefreshInterval {
            return
        }
        isRefreshing = true
        lastPassStartedAt = Date()
        defer { isRefreshing = false }
        async let claudeResult = claudeFetch()
        async let codexResult = codexFetch()
        let (newClaude, newCodex) = await (claudeResult, codexResult)
        // Keep last-good data on transient failures: a failed pass only
        // replaces a ready state with failure when we never had data.
        claude = Self.merging(current: claude, incoming: newClaude)
        codex = Self.merging(current: codex, incoming: newCodex)
    }

    static func merging<Snapshot>(
        current: SupermuxUsageProviderState<Snapshot>,
        incoming: SupermuxUsageProviderState<Snapshot>
    ) -> SupermuxUsageProviderState<Snapshot> {
        switch (current, incoming) {
        case (.ready, .failed):
            return current
        default:
            return incoming
        }
    }
}

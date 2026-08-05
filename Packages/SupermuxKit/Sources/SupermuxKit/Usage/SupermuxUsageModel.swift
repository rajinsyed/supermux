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
    /// Slot currently being switched to via cswap, `nil` when idle. Drives
    /// the per-row spinner and disables other switch buttons meanwhile.
    public private(set) var switchingToSlot: Int?
    /// The last switch failure, cleared on the next successful switch or
    /// explicit dismissal. Rendered inline in the popover's Claude section.
    public private(set) var lastSwitchError: String?

    @ObservationIgnored private let claudeFetch: @Sendable () async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>
    @ObservationIgnored private let codexFetch: @Sendable () async -> SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>
    @ObservationIgnored private let claudeSwitch: @Sendable (Int) async -> SupermuxCswapSwitchResult
    @ObservationIgnored private let claudeSwitchBest: @Sendable () async -> SupermuxCswapSwitchResult
    @ObservationIgnored private let claudeSetEnabled: @Sendable (Bool, Int) async -> SupermuxCswapSwitchResult
    @ObservationIgnored private let pollInterval: Duration
    /// Hard floor between passes — applied to EVERY refresh entry point, so
    /// neither the poll loop, popover opens, nor the manual refresh button can
    /// drive more than one pass per floor interval.
    @ObservationIgnored private let minimumRefreshInterval: TimeInterval
    @ObservationIgnored private var lastPassStartedAt: Date?
    /// Set when a mutation completes while a pass is in flight; the running
    /// pass immediately runs one more (its own results describe the
    /// pre-mutation world and are discarded via `accountStateGeneration`).
    @ObservationIgnored private var pendingForcedRefresh = false
    /// Whether the queued follow-up came from an account SWITCH (bypasses
    /// the Claude staleness gate) rather than an enable/disable toggle.
    @ObservationIgnored private var pendingActiveAccountChanged = false
    /// Bumped on every successful cswap mutation. A pass that started under
    /// an older generation measured pre-mutation state and must not publish.
    @ObservationIgnored private var accountStateGeneration = 0
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
        self.claudeSwitch = { await claudeSource.switchAccount(toSlot: $0) }
        self.claudeSwitchBest = { await claudeSource.switchToBestAccount() }
        self.claudeSetEnabled = { await claudeSource.setAccountEnabled($0, slot: $1) }
        self.pollInterval = pollInterval
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    /// Test seam: inject fetch/switch closures directly.
    init(
        claudeFetch: @escaping @Sendable () async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>,
        codexFetch: @escaping @Sendable () async -> SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>,
        claudeSwitch: @escaping @Sendable (Int) async -> SupermuxCswapSwitchResult = { _ in .failed(message: "unavailable") },
        claudeSwitchBest: @escaping @Sendable () async -> SupermuxCswapSwitchResult = { .failed(message: "unavailable") },
        claudeSetEnabled: @escaping @Sendable (Bool, Int) async -> SupermuxCswapSwitchResult = { _, _ in .failed(message: "unavailable") },
        pollInterval: Duration = .seconds(120),
        minimumRefreshInterval: TimeInterval = 30
    ) {
        self.claudeFetch = claudeFetch
        self.codexFetch = codexFetch
        self.claudeSwitch = claudeSwitch
        self.claudeSwitchBest = claudeSwitchBest
        self.claudeSetEnabled = claudeSetEnabled
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
    ///
    /// For Claude the per-account measurement times are used, not the
    /// snapshot's parse time: cswap serves cached measurements, so the parse
    /// moment says nothing about how old the displayed numbers are.
    public var oldestDisplayedDataAge: Date? {
        var dates: [Date] = []
        if let claudeSnapshot = claude.snapshot {
            let accountDates = claudeSnapshot.accounts.compactMap(\.fetchedAt)
            dates.append(accountDates.min() ?? claudeSnapshot.fetchedAt)
        }
        if let codexSnapshot = codex.snapshot {
            dates.append(codexSnapshot.fetchedAt)
        }
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

    /// What a `refresh()` call actually did, so the UI can acknowledge a
    /// throttled click ("Up to date") instead of silently doing nothing.
    public enum RefreshOutcome: Sendable, Equatable {
        case refreshed
        case throttled
        case alreadyRefreshing
    }

    /// One pass over both providers, concurrently. The floor applies here —
    /// to every caller — so repeated popover opens or refresh-button clicks
    /// coalesce into at most one pass per `minimumRefreshInterval`.
    @discardableResult
    public func refresh() async -> RefreshOutcome {
        await refresh(forced: false)
    }

    /// `forced` passes (post-mutation) bypass the floor, and when a pass is
    /// already in flight they queue exactly one follow-up instead of being
    /// dropped — the in-flight pass measured pre-mutation state.
    /// `activeAccountChanged` marks a pass whose incoming Claude snapshot
    /// describes a different active account (a switch), which additionally
    /// bypasses the staleness gate; enable/disable toggles do not set it.
    @discardableResult
    private func refresh(forced: Bool, activeAccountChanged: Bool = false) async -> RefreshOutcome {
        guard !isRefreshing else {
            if forced {
                pendingForcedRefresh = true
                pendingActiveAccountChanged = pendingActiveAccountChanged || activeAccountChanged
            }
            return .alreadyRefreshing
        }
        if !forced, let last = lastPassStartedAt,
           Date().timeIntervalSince(last) < minimumRefreshInterval {
            return .throttled
        }
        isRefreshing = true
        defer { isRefreshing = false }
        // repeat, not recursion: recursing would re-enter before the defer
        // clears isRefreshing and trip the guard above.
        var switchDriven = activeAccountChanged
        repeat {
            pendingForcedRefresh = false
            pendingActiveAccountChanged = false
            lastPassStartedAt = Date()
            let generation = accountStateGeneration
            async let claudeResult = claudeFetch()
            async let codexResult = codexFetch()
            let (newClaude, newCodex) = await (claudeResult, codexResult)
            // A cancelled pass (the owning sidebar unmounted mid-fetch)
            // measured nothing trustworthy — CommandRunner reports the
            // cancellation as a generic failure the sources can't tell from
            // a real one. Don't publish it, and let the next owner re-run
            // immediately instead of waiting out the floor.
            if Task.isCancelled {
                lastPassStartedAt = nil
                return .refreshed
            }
            // Results measured before a completed cswap mutation describe
            // the old active/enabled state; drop them rather than paint them.
            if generation == accountStateGeneration {
                // A switch-driven pass bypasses the Claude staleness gate:
                // the ACTIVE ACCOUNT just changed, so comparing the new
                // account's (possibly older) cached measurement against the
                // previous account's is meaningless — the switched-to
                // account must be shown regardless. Enable/disable toggles
                // do NOT bypass it (the active account is unchanged, so the
                // gate's same-account comparison stays valid).
                claude = Self.merging(
                    current: claude, incoming: newClaude, preferIncoming: switchDriven
                )
                codex = Self.merging(current: codex, incoming: newCodex)
            }
            switchDriven = pendingActiveAccountChanged
        } while pendingForcedRefresh
        return .refreshed
    }

    /// Switches the active Claude Code login to a cswap slot, then forces a
    /// refresh (bypassing the floor — the data legitimately just changed) so
    /// the popover re-labels the active account and its windows.
    public func switchClaudeAccount(toSlot slot: Int) async {
        guard switchingToSlot == nil else { return }
        switchingToSlot = slot
        defer { switchingToSlot = nil }
        let result = await claudeSwitch(slot)
        switch result {
        case .switched, .alreadyActive:
            lastSwitchError = nil
            // The floor exists to protect the usage endpoint from UI spam; a
            // completed switch is a real state change, and the cswap path
            // (the only way to get here) serves from cswap's cache anyway.
            accountStateGeneration &+= 1
            await refresh(forced: true, activeAccountChanged: true)
        case .failed(let message):
            lastSwitchError = message
        }
    }

    /// Clears an inline switch-failure note.
    public func dismissSwitchError() {
        lastSwitchError = nil
    }

    /// `cswap switch --strategy best`: switch to the account with the most
    /// remaining quota. Uses slot marker -1 for the in-flight indicator
    /// (no specific target row spins; the Best button itself does).
    public func switchClaudeToBest() async {
        guard switchingToSlot == nil else { return }
        switchingToSlot = -1
        defer { switchingToSlot = nil }
        let result = await claudeSwitchBest()
        switch result {
        case .switched, .alreadyActive:
            lastSwitchError = nil
            accountStateGeneration &+= 1
            await refresh(forced: true, activeAccountChanged: true)
        case .failed(let message):
            lastSwitchError = message
        }
    }

    /// Whether the switch-to-best action is currently in flight.
    public var isSwitchingToBest: Bool { switchingToSlot == -1 }

    /// Whether everything on display is genuinely current: each provider is
    /// `.ready` with healthy credentials AND a measurement no older than one
    /// poll period plus cswap's serve TTL — cswap can serve hours-old cache
    /// with `.ok` status, which must not be acknowledged as fresh.
    /// `.notConfigured` doesn't block (nothing to be stale). Drives the
    /// popover's "Up to date" flash on throttled refresh clicks.
    public var isDisplayedDataFresh: Bool {
        // Poll cadence (120s) + cswap's ~180s serve TTL, with slack.
        let tolerance: TimeInterval = 360
        let claudeFresh: Bool = switch claude {
        case .notConfigured: true
        case .ready(let snapshot):
            snapshot.activeAccount?.status == .ok
                && Date().timeIntervalSince(snapshot.measuredAt) < tolerance
        case .failed, .needsLogin, .loading: false
        }
        let codexFresh: Bool = switch codex {
        case .notConfigured: true
        case .ready(let snapshot):
            snapshot.source == .api && !snapshot.needsRelogin
                && Date().timeIntervalSince(snapshot.measuredAt) < tolerance
        case .failed, .needsLogin, .loading: false
        }
        return claudeFresh && codexFresh
    }

    /// `cswap enable/disable <slot>`. Refreshes on success so the row's
    /// dimmed state follows immediately.
    public func setClaudeAccountEnabled(_ enabled: Bool, slot: Int) async {
        guard switchingToSlot == nil else { return }
        switchingToSlot = slot
        defer { switchingToSlot = nil }
        let result = await claudeSetEnabled(enabled, slot)
        switch result {
        case .switched, .alreadyActive:
            lastSwitchError = nil
            accountStateGeneration &+= 1
            await refresh(forced: true)
        case .failed(let message):
            lastSwitchError = message
        }
    }

    /// `preferIncoming` skips the staleness gate for mutation-driven passes:
    /// after an account switch the incoming snapshot describes a DIFFERENT
    /// active account, so cross-account measurement-time comparison would
    /// wrongly discard it whenever the switched-to account's cache is older.
    static func merging<Snapshot: SupermuxTimestampedUsageSnapshot>(
        current: SupermuxUsageProviderState<Snapshot>,
        incoming: SupermuxUsageProviderState<Snapshot>,
        preferIncoming: Bool = false
    ) -> SupermuxUsageProviderState<Snapshot> {
        switch (current, incoming) {
        case (.ready, .failed):
            return current
        case (.ready(let held), .ready(let fresh))
            where !preferIncoming && fresh.measuredAt < held.measuredAt:
            // A degraded pass can serve an OLDER measurement (Codex falls
            // back to the last session log on transient API trouble; a cswap
            // pass can carry only cached lastGoodUsage). Compare measurement
            // times, not parse times — never replace newer displayed data.
            return current
        default:
            return incoming
        }
    }
}

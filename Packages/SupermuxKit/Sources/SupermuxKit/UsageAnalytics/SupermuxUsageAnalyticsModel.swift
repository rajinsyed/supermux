public import Foundation
public import Observation

/// App-wide model behind the sidebar analytics button: owns the scanned usage
/// history and recomputes the selected range's report on demand.
///
/// Scanning is expensive the first time (several gigabytes of session logs)
/// and nearly free afterwards — the per-file cache means a refresh only
/// reparses files that actually changed. So the model scans lazily: nothing
/// happens until the popover is first opened, and later opens are throttled by
/// ``minimumRefreshInterval`` the same way the usage-limits tracker throttles
/// its network calls.
///
/// Unlike the limits tracker there is no poll loop — local log files only
/// change when the user runs an agent, and the numbers are historical rather
/// than live, so re-reading on open is enough.
@MainActor
@Observable
public final class SupermuxUsageAnalyticsModel {
    /// Everything scanned so far. Published mid-scan so a cold run fills in
    /// progressively instead of showing an empty popover for a minute.
    public private(set) var snapshot: SupermuxUsageAnalyticsSnapshot = .empty
    public private(set) var isScanning = false
    /// The range the popover is showing; changing it only recomputes the
    /// report, never rescans.
    public var selectedRange: SupermuxAnalyticsRange = .month {
        didSet {
            guard oldValue != selectedRange else { return }
            recomputeReport()
        }
    }

    /// The aggregated view of ``snapshot`` for ``selectedRange``.
    public private(set) var report: SupermuxUsageAnalyticsReport = .empty(range: .month)

    @ObservationIgnored private let scan: @Sendable (
        [SupermuxUsageAnalyticsEntry],
        @escaping @Sendable (SupermuxUsageAnalyticsSnapshot) -> Void
    ) async -> SupermuxUsageAnalyticsSnapshot
    @ObservationIgnored private let minimumRefreshInterval: TimeInterval
    /// Optional observer used by tests to await an attempted partial application.
    @ObservationIgnored private let didAttemptApply: @MainActor (SupermuxUsageAnalyticsSnapshot) -> Void
    @ObservationIgnored private var lastScanStartedAt: Date?
    @ObservationIgnored private var hasScannedOnce = false
    /// Incremented per scan. Partial results carry the generation they came
    /// from, so a straggler from an older pass is dropped by identity rather
    /// than by comparing wall-clock times — which a clock change can reorder,
    /// and which cannot distinguish "older scan" from "earlier in this scan".
    @ObservationIgnored private var scanGeneration = 0
    /// The generation whose data is currently displayed.
    @ObservationIgnored private var displayedGeneration = 0

    public enum RefreshOutcome: Sendable, Equatable {
        case scanned
        case throttled
        case alreadyScanning
    }

    public init(
        claudeScanner: SupermuxClaudeUsageLogScanner = SupermuxClaudeUsageLogScanner(),
        codexScanner: SupermuxCodexUsageLogScanner = SupermuxCodexUsageLogScanner(),
        minimumRefreshInterval: TimeInterval = 30
    ) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.didAttemptApply = { _ in }
        self.scan = { previousEntries, publish in
            await SupermuxUsageAnalyticsScanCoordinator.scan(
                claudeScanner: claudeScanner,
                codexScanner: codexScanner,
                previousEntries: previousEntries,
                publish: publish
            )
        }
    }

    /// Test seam: inject the whole scan.
    init(
        scan: @escaping @Sendable (
            [SupermuxUsageAnalyticsEntry],
            @escaping @Sendable (SupermuxUsageAnalyticsSnapshot) -> Void
        ) async -> SupermuxUsageAnalyticsSnapshot,
        minimumRefreshInterval: TimeInterval = 30,
        didAttemptApply: @escaping @MainActor (SupermuxUsageAnalyticsSnapshot) -> Void = { _ in }
    ) {
        self.scan = scan
        self.minimumRefreshInterval = minimumRefreshInterval
        self.didAttemptApply = didAttemptApply
    }

    /// Scans if enough time has passed since the last pass. The first call
    /// always scans regardless of the floor, so opening the popover for the
    /// first time is never a no-op.
    @discardableResult
    public func refresh(force: Bool = false) async -> RefreshOutcome {
        guard !isScanning else { return .alreadyScanning }
        if !force, hasScannedOnce, let last = lastScanStartedAt,
           Date().timeIntervalSince(last) < minimumRefreshInterval {
            return .throttled
        }

        lastScanStartedAt = Date()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        defer {
            isScanning = false
            hasScannedOnce = true
        }

        let publish: @Sendable (SupermuxUsageAnalyticsSnapshot) -> Void = { [weak self] partial in
            Task { @MainActor in
                self?.apply(partial, generation: generation)
            }
        }
        let result = await scan(snapshot.entries, publish)
        guard !Task.isCancelled else { return .scanned }
        apply(result, generation: generation)
        return .scanned
    }

    private func apply(_ snapshot: SupermuxUsageAnalyticsSnapshot, generation: Int) {
        didAttemptApply(snapshot)
        // Never regress: a straggling partial from this or an earlier scan
        // must not replace data a later pass already completed, and a partial
        // never overwrites the complete result of the same pass.
        if generation < displayedGeneration { return }
        if generation == displayedGeneration, self.snapshot.isComplete, !snapshot.isComplete {
            return
        }
        displayedGeneration = generation
        self.snapshot = snapshot
        recomputeReport()
    }

    private func recomputeReport() {
        report = SupermuxUsageAnalyticsAggregator.report(from: snapshot, range: selectedRange)
    }

    /// When the displayed numbers were last read off disk, or `nil` before the
    /// first scan finishes.
    public var lastScanFinishedAt: Date? {
        snapshot.isComplete && hasScannedOnce ? snapshot.generatedAt : nil
    }

    /// 0…1 progress for the popover's bar.
    ///
    /// A scan that has not published its first file count yet is at zero, not
    /// at the `1` the still-complete previous snapshot reports — otherwise
    /// opening the popover cold shows a full bar reading "100%" for the second
    /// before the first partial lands, then jumps backwards.
    public var scanProgress: Double {
        guard isScanning else { return 1 }
        guard !snapshot.isComplete else { return 0 }
        return snapshot.scanProgress
    }
}

/// Runs both scanners off the main actor and merges their output.
enum SupermuxUsageAnalyticsScanCoordinator {
    static func scan(
        claudeScanner: SupermuxClaudeUsageLogScanner,
        codexScanner: SupermuxCodexUsageLogScanner,
        previousEntries: [SupermuxUsageAnalyticsEntry],
        publish: @escaping @Sendable (SupermuxUsageAnalyticsSnapshot) -> Void
    ) async -> SupermuxUsageAnalyticsSnapshot {
        var missing: Set<SupermuxAnalyticsProvider> = []
        if !claudeScanner.isAvailable { missing.insert(.claudeCode) }
        if !codexScanner.isAvailable { missing.insert(.codex) }

        // Each scanner reports its own file progress; the shared box merges
        // both into one snapshot so the popover shows a single progress bar
        // and both providers' partial data at once. It starts from what is
        // already on screen, so the first provider to report cannot blank out
        // the other's previous totals mid-refresh.
        let box = ProgressBox(
            missingProviders: missing,
            seed: previousEntries,
            publish: publish
        )

        let claudeTask = Task.detached(priority: .utility) {
            let entries = claudeScanner.scan { scanned, total, entries in
                box.update(provider: .claudeCode, scanned: scanned, total: total, entries: entries)
            }
            // A scanner that finishes with nothing must clear its seeded rows;
            // its progress callbacks alone never fire for an empty walk, so the
            // previous pass's entries would linger in the partial snapshots.
            box.finish(provider: .claudeCode, entries: entries)
            return entries
        }
        let codexTask = Task.detached(priority: .utility) {
            let entries = codexScanner.scan { scanned, total, entries in
                box.update(provider: .codex, scanned: scanned, total: total, entries: entries)
            }
            box.finish(provider: .codex, entries: entries)
            return entries
        }
        // Detached tasks do not inherit cancellation; without this the scans
        // keep reading gigabytes after the caller has given up.
        return await withTaskCancellationHandler {
            let claudeEntries = await claudeTask.value
            let codexEntries = await codexTask.value
            return SupermuxUsageAnalyticsSnapshot(
                entries: claudeEntries + codexEntries,
                generatedAt: Date(),
                isComplete: true,
                scannedFileCount: 0,
                totalFileCount: 0,
                missingProviders: missing
            )
        } onCancel: {
            claudeTask.cancel()
            codexTask.cancel()
        }
    }
}

/// Thread-safe merge point for the two scanners' progress callbacks.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private let missingProviders: Set<SupermuxAnalyticsProvider>
    private let publish: @Sendable (SupermuxUsageAnalyticsSnapshot) -> Void
    private var entries: [SupermuxAnalyticsProvider: [SupermuxUsageAnalyticsEntry]] = [:]
    private var scanned: [SupermuxAnalyticsProvider: Int] = [:]
    private var totals: [SupermuxAnalyticsProvider: Int] = [:]
    private var lastPublishedAt = Date.distantPast

    init(
        missingProviders: Set<SupermuxAnalyticsProvider>,
        seed: [SupermuxUsageAnalyticsEntry],
        publish: @escaping @Sendable (SupermuxUsageAnalyticsSnapshot) -> Void
    ) {
        self.missingProviders = missingProviders
        self.publish = publish
        self.entries = Dictionary(grouping: seed, by: \.provider)
    }

    /// Replaces a provider's rows with its final result without publishing —
    /// the completed snapshot follows immediately and would only be duplicated.
    func finish(provider: SupermuxAnalyticsProvider, entries: [SupermuxUsageAnalyticsEntry]) {
        lock.lock()
        self.entries[provider] = entries
        lock.unlock()
    }

    func update(
        provider: SupermuxAnalyticsProvider,
        scanned: Int,
        total: Int,
        entries: [SupermuxUsageAnalyticsEntry]
    ) {
        lock.lock()
        self.entries[provider] = entries
        self.scanned[provider] = scanned
        self.totals[provider] = total
        // Republishing on every file would thrash the aggregator over tens of
        // thousands of entries; a quarter second is well under the threshold
        // where a filling bar stops feeling live.
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) > 0.25 else {
            lock.unlock()
            return
        }
        lastPublishedAt = now
        let snapshot = SupermuxUsageAnalyticsSnapshot(
            entries: self.entries.values.flatMap { $0 },
            generatedAt: now,
            isComplete: false,
            scannedFileCount: self.scanned.values.reduce(0, +),
            totalFileCount: self.totals.values.reduce(0, +),
            missingProviders: missingProviders
        )
        lock.unlock()
        publish(snapshot)
    }
}

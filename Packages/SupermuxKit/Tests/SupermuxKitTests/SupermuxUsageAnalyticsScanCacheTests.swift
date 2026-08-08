import Foundation
import Testing

@testable import SupermuxKit

/// Regressions for defects an adversarial review of the scan plumbing found:
/// a tolerant mtime comparison that served stale numbers forever, and a line
/// reader that recopied its buffer once per line.
@Suite struct SupermuxUsageAnalyticsScanCacheTests {
    @Test func mtimeComparisonIsExactSoASameSizeRewriteIsRescanned() {
        let scanned = SupermuxScannedFile(
            path: "/tmp/a.jsonl",
            size: 100,
            modifiedAt: Date(timeIntervalSince1970: 1_000_000),
            entries: []
        )
        #expect(scanned.matches(size: 100, modifiedAt: Date(timeIntervalSince1970: 1_000_000)))
        // A rewrite 200ms later at the same size used to fall inside a 0.5s
        // tolerance and serve the pre-rewrite totals indefinitely.
        #expect(!scanned.matches(size: 100, modifiedAt: Date(timeIntervalSince1970: 1_000_000.2)))
        #expect(!scanned.matches(size: 101, modifiedAt: Date(timeIntervalSince1970: 1_000_000)))
    }

    /// The stat signature has to survive the JSON round trip exactly, or every
    /// launch rescans everything.
    @Test func cacheRoundTripPreservesTheStatSignature() throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_786_000_123.456)
        let file = SupermuxScannedFile(path: "/tmp/a.jsonl", size: 42, modifiedAt: modifiedAt, entries: [])
        let decoded = try JSONDecoder().decode(
            SupermuxScannedFile.self,
            from: try JSONEncoder().encode(file)
        )
        #expect(decoded.matches(size: 42, modifiedAt: modifiedAt))
    }

    /// The window must cover the longest range the popover offers, or the
    /// 90-day view would silently lose its oldest days.
    @Test func scanWindowCoversTheLongestRange() {
        #expect(SupermuxUsageScanWindow.dayCount > SupermuxAnalyticsRange.quarter.dayCount)
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let earliest = SupermuxUsageScanWindow.earliestRelevantModification(now: now)
        #expect(now.timeIntervalSince(earliest) == 91 * 24 * 60 * 60)
    }

    /// Stale files must leave the cache, or it grows forever and keeps
    /// reporting logs the user deleted.
    @Test func pruningDropsAgedOutAndDeletedFiles() throws {
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-live-\(UUID().uuidString).jsonl")
        try "{}".write(to: live, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: live) }

        let now = Date()
        var cache = SupermuxUsageAnalyticsCache(files: [
            live.path: SupermuxScannedFile(path: live.path, size: 2, modifiedAt: now, entries: []),
            "/tmp/deleted-\(UUID().uuidString).jsonl": SupermuxScannedFile(
                path: "/tmp/deleted.jsonl", size: 2, modifiedAt: now, entries: []
            ),
            "/tmp/ancient.jsonl": SupermuxScannedFile(
                path: "/tmp/ancient.jsonl",
                size: 2,
                modifiedAt: now.addingTimeInterval(-200 * 24 * 60 * 60),
                entries: []
            ),
        ])
        cache.prune(earliestRelevant: SupermuxUsageScanWindow.earliestRelevantModification(now: now))
        #expect(cache.files.keys.sorted() == [live.path])
    }

    @Test func readerEmitsEveryLineIncludingAnUnterminatedTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-lines-\(UUID().uuidString).txt")
        try "alpha\nbeta\n\ngamma".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var lines: [String] = []
        let didRead = SupermuxLineReader.forEachLine(in: url) { data in
            lines.append(String(decoding: data, as: UTF8.self))
        }
        #expect(didRead)
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    /// Lines are emitted correctly when they straddle read-chunk boundaries —
    /// the case the in-place buffer consumption has to get right.
    @Test func readerHandlesLinesSpanningChunkBoundaries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-lines-\(UUID().uuidString).txt")
        let expected = (0..<500).map { "line-\($0)-\(String(repeating: "x", count: 37))" }
        try expected.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var lines: [String] = []
        SupermuxLineReader.forEachLine(in: url, chunkSize: 64) { data in
            lines.append(String(decoding: data, as: UTF8.self))
        }
        #expect(lines == expected)
    }

    /// A file with no newlines must not be buffered without bound; the
    /// oversized span is dropped and scanning resumes at the next line.
    @Test func readerSkipsAnOverlongLineAndResumesAfterIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-lines-\(UUID().uuidString).txt")
        let huge = String(repeating: "y", count: SupermuxLineReader.maximumLineBytes + 4096)
        try "\(huge)\nsurvivor".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var lines: [String] = []
        SupermuxLineReader.forEachLine(in: url) { data in
            lines.append(String(decoding: data, as: UTF8.self))
        }
        #expect(lines == ["survivor"])
    }

    /// Many short lines in one chunk used to recopy the remaining buffer per
    /// line, which cost seconds for a single megabyte.
    @Test func readerStaysLinearOverManyShortLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-lines-\(UUID().uuidString).txt")
        let line = String(repeating: "z", count: 19)
        try Array(repeating: line, count: 60_000).joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var count = 0
        let started = Date()
        SupermuxLineReader.forEachLine(in: url) { _ in count += 1 }
        let elapsed = Date().timeIntervalSince(started)
        #expect(count == 60_000)
        // Quadratic copying measured ~2.9s for this shape; linear is milliseconds.
        #expect(elapsed < 1.0)
    }
}

@Suite @MainActor struct SupermuxUsageAnalyticsModelTests {
    private func entry(_ provider: SupermuxAnalyticsProvider, output: Int) -> SupermuxUsageAnalyticsEntry {
        SupermuxUsageAnalyticsEntry(
            day: Calendar.current.startOfDay(for: Date()),
            provider: provider,
            model: provider == .claudeCode ? "claude-fable-5" : "gpt-5.6-sol",
            tokens: SupermuxTokenCounts(output: output)
        )
    }

    /// A partial published late in a pass must not erase that pass's own
    /// completed result.
    @Test func latePartialDoesNotClobberTheCompletedScan() async {
        let model = SupermuxUsageAnalyticsModel(
            scan: { _, publish in
                publish(SupermuxUsageAnalyticsSnapshot(entries: [], isComplete: false))
                return SupermuxUsageAnalyticsSnapshot(
                    entries: [
                        SupermuxUsageAnalyticsEntry(
                            day: Calendar.current.startOfDay(for: Date()),
                            provider: .claudeCode,
                            model: "claude-fable-5",
                            tokens: SupermuxTokenCounts(output: 1000)
                        ),
                    ],
                    isComplete: true
                )
            },
            minimumRefreshInterval: 0
        )
        await model.refresh()
        // Give any queued partial hop to the main actor a chance to land.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.snapshot.isComplete)
        #expect(model.report.tokens.output == 1000)
    }

    /// A scan in flight must not report the *previous* complete snapshot's
    /// progress. `snapshot.scanProgress` returns 1 while `isComplete`, so the
    /// popover opened cold on a full bar reading 100%, then jumped backwards
    /// once the first partial landed.
    @Test func progressStartsAtZeroWhileAScanHasNotPublishedYet() async {
        let gate = ScanGate()
        let model = SupermuxUsageAnalyticsModel(
            scan: { _, _ in
                await gate.waitUntilObserved()
                return SupermuxUsageAnalyticsSnapshot(entries: [], isComplete: true)
            },
            minimumRefreshInterval: 0
        )
        #expect(model.scanProgress == 1)
        let refresh = Task { await model.refresh() }
        while !model.isScanning { await Task.yield() }
        #expect(model.scanProgress == 0)
        await gate.release()
        _ = await refresh.value
        #expect(model.scanProgress == 1)
    }

    @Test func refreshHonorsTheFloorAfterTheFirstScan() async {
        let model = SupermuxUsageAnalyticsModel(
            scan: { _, _ in SupermuxUsageAnalyticsSnapshot(entries: [], isComplete: true) },
            minimumRefreshInterval: 600
        )
        #expect(await model.refresh() == .scanned)
        #expect(await model.refresh() == .throttled)
        // An explicit refresh-button press bypasses the floor.
        #expect(await model.refresh(force: true) == .scanned)
    }

    @Test func changingRangeRecomputesWithoutRescanning() async {
        let calls = ScanCounter()
        let model = SupermuxUsageAnalyticsModel(
            scan: { _, _ in
                calls.increment()
                return SupermuxUsageAnalyticsSnapshot(entries: [], isComplete: true)
            },
            minimumRefreshInterval: 600
        )
        await model.refresh()
        model.selectedRange = .quarter
        #expect(model.report.range == .quarter)
        #expect(model.report.daily.count == 90)
        #expect(calls.value == 1)
    }

    /// The previous pass's numbers are handed to the next scan, so a provider
    /// that reports first cannot blank out the other provider mid-refresh.
    @Test func warmRescanKeepsTheOtherProvidersPreviousTotals() async {
        let seeded = SeedRecorder()
        let model = SupermuxUsageAnalyticsModel(
            scan: { previous, _ in
                seeded.record(previous)
                return SupermuxUsageAnalyticsSnapshot(
                    entries: [
                        SupermuxUsageAnalyticsEntry(
                            day: Calendar.current.startOfDay(for: Date()),
                            provider: .claudeCode,
                            model: "claude-fable-5",
                            tokens: SupermuxTokenCounts(output: 500)
                        ),
                    ],
                    isComplete: true
                )
            },
            minimumRefreshInterval: 0
        )
        await model.refresh()
        await model.refresh()
        #expect(seeded.lastCount == 1)
    }
}

/// Holds a fake scan open until the test has observed the in-flight state.
private actor ScanGate {
    private var isReleased = false

    func release() {
        isReleased = true
    }

    func waitUntilObserved() async {
        while !isReleased {
            await Task.yield()
        }
    }
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class SeedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func record(_ entries: [SupermuxUsageAnalyticsEntry]) {
        lock.lock()
        counts.append(entries.count)
        lock.unlock()
    }

    var lastCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.last ?? -1
    }
}

import Foundation
import Testing

@testable import SupermuxKit

@Suite struct SupermuxClaudeUsageLogScannerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        return calendar
    }()

    /// A fresh projects dir + cache dir per test, so nothing leaks between runs.
    private func makeSandbox() throws -> (projects: URL, cache: SupermuxUsageAnalyticsCacheStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-claude-scan-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return (projects, SupermuxUsageAnalyticsCacheStore(directory: cacheDir), root)
    }

    private func write(_ lines: [String], to directory: URL, named name: String = "session.jsonl") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assistantLine(
        id: String,
        model: String = "claude-fable-5",
        timestamp: String = "2026-08-08T12:44:53.506Z",
        input: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        isSidechain: Bool = false
    ) -> String {
        """
        {"type":"assistant","isSidechain":\(isSidechain),"uuid":"u-\(id)","timestamp":"\(timestamp)",\
        "message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),\
        "cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead),\
        "output_tokens":\(output),"cache_creation":{"ephemeral_5m_input_tokens":\(cacheCreation),\
        "ephemeral_1h_input_tokens":0},"service_tier":"standard","iterations":[]}}}
        """
    }

    private func scanner(projects: URL, cache: SupermuxUsageAnalyticsCacheStore) -> SupermuxClaudeUsageLogScanner {
        SupermuxClaudeUsageLogScanner(projectsDirectory: projects, cacheStore: cache, calendar: calendar)
    }

    /// Streaming flushes rewrite an assistant entry several times; only the
    /// final one holds the completed output count. Summing them would roughly
    /// double every number in the popover.
    @Test func repeatedMessageIdKeepsTheLastOccurrence() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            assistantLine(id: "msg_1", output: 10),
            assistantLine(id: "msg_1", output: 900),
            assistantLine(id: "msg_1", output: 2865),
        ], to: sandbox.projects)

        let entries = scanner(projects: sandbox.projects, cache: sandbox.cache).scan()
        #expect(entries.count == 1)
        #expect(entries.first?.tokens.output == 2865)
    }

    /// Subagent transcripts are real billed API calls, not a duplicate view of
    /// the main thread — excluding them would undercount heavily.
    @Test func sidechainEntriesAreCounted() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            assistantLine(id: "msg_main", output: 100),
            assistantLine(id: "msg_sub", output: 400, isSidechain: true),
        ], to: sandbox.projects)

        let entries = scanner(projects: sandbox.projects, cache: sandbox.cache).scan()
        #expect(entries.reduce(0) { $0 + $1.tokens.output } == 500)
    }

    @Test func syntheticPlaceholdersAreSkipped() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            assistantLine(id: "msg_real", output: 100),
            assistantLine(id: "msg_fake", model: "<synthetic>", output: 999),
        ], to: sandbox.projects)

        let entries = scanner(projects: sandbox.projects, cache: sandbox.cache).scan()
        #expect(entries.count == 1)
        #expect(entries.first?.tokens.output == 100)
    }

    @Test func nonAssistantLinesAreIgnored() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            #"{"type":"user","timestamp":"2026-08-08T12:00:00.000Z","message":{"role":"user"}}"#,
            #"{"type":"summary","summary":"something"}"#,
            assistantLine(id: "msg_1", output: 42),
        ], to: sandbox.projects)

        let entries = scanner(projects: sandbox.projects, cache: sandbox.cache).scan()
        #expect(entries.count == 1)
        #expect(entries.first?.tokens.output == 42)
    }

    /// The four token classes must land in their normalized slots, since
    /// Claude's `input_tokens` already excludes cache reads and writes.
    @Test func mapsClaudeUsageFieldsWithoutOverlap() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            assistantLine(id: "msg_1", input: 2, cacheCreation: 14403, cacheRead: 44252, output: 2865),
        ], to: sandbox.projects)

        let tokens = try #require(scanner(projects: sandbox.projects, cache: sandbox.cache).scan().first?.tokens)
        #expect(tokens.uncachedInput == 2)
        #expect(tokens.cacheWrite == 14403)
        #expect(tokens.cacheRead == 44252)
        #expect(tokens.output == 2865)
        #expect(tokens.observedInput == 58657)
    }

    /// UTC timestamps must bucket into the *local* day, or late-evening usage
    /// lands on tomorrow's bar.
    @Test func bucketsUtcTimestampsIntoLocalDays() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            // 03:00Z on the 9th is 19:00 on the 8th at GMT-8.
            assistantLine(id: "msg_1", timestamp: "2026-08-09T03:00:00.000Z", output: 10),
        ], to: sandbox.projects)

        let day = try #require(scanner(projects: sandbox.projects, cache: sandbox.cache).scan().first?.day)
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        #expect(components.day == 8)
        #expect(components.month == 8)
    }

    @Test func splitsEntriesPerModelAndPerDay() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            assistantLine(id: "a", model: "claude-fable-5", timestamp: "2026-08-08T20:00:00.000Z", output: 10),
            assistantLine(id: "b", model: "claude-opus-5", timestamp: "2026-08-08T20:00:00.000Z", output: 20),
            assistantLine(id: "c", model: "claude-fable-5", timestamp: "2026-08-07T20:00:00.000Z", output: 30),
        ], to: sandbox.projects)

        let entries = scanner(projects: sandbox.projects, cache: sandbox.cache).scan()
        #expect(entries.count == 3)
    }

    @Test func findsTranscriptsInNestedProjectDirectories() throws {
        let sandbox = try makeSandbox()
        let nested = sandbox.projects.appendingPathComponent("-Users-someone-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try write([assistantLine(id: "msg_1", output: 7)], to: nested)

        let entries = scanner(projects: sandbox.projects, cache: sandbox.cache).scan()
        #expect(entries.first?.tokens.output == 7)
    }

    /// The cache is what makes a warm pass milliseconds instead of minutes:
    /// an unchanged (size, mtime) must serve stored aggregates without
    /// re-reading the file.
    @Test func unchangedFileServesCachedAggregatesWithoutRereading() throws {
        let sandbox = try makeSandbox()
        let url = try write([assistantLine(id: "msg_1", output: 100)], to: sandbox.projects)
        let scanner = scanner(projects: sandbox.projects, cache: sandbox.cache)
        #expect(scanner.scan().first?.tokens.output == 100)

        // Rewrite the contents but restore the original stat signature; a
        // scanner that re-read the bytes would report 555.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalDate = try #require(attributes[.modificationDate] as? Date)
        var replacement = assistantLine(id: "msg_1", output: 555)
        // Pad to the original byte length so size matches too.
        let originalSize = try #require(attributes[.size] as? Int)
        while replacement.utf8.count < originalSize { replacement += " " }
        try replacement.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)

        #expect(scanner.scan().first?.tokens.output == 100)
    }

    @Test func changedFileReplacesOnlyItsOwnContribution() throws {
        let sandbox = try makeSandbox()
        _ = try write([assistantLine(id: "a", output: 100)], to: sandbox.projects, named: "one.jsonl")
        let second = try write([assistantLine(id: "b", output: 200)], to: sandbox.projects, named: "two.jsonl")
        let scanner = scanner(projects: sandbox.projects, cache: sandbox.cache)
        #expect(scanner.scan().reduce(0) { $0 + $1.tokens.output } == 300)

        try (assistantLine(id: "b", output: 200) + "\n" + assistantLine(id: "c", output: 50))
            .write(to: second, atomically: true, encoding: .utf8)
        #expect(scanner.scan().reduce(0) { $0 + $1.tokens.output } == 350)
    }

    @Test func missingDirectoryIsUnavailableAndYieldsNoEntries() throws {
        let sandbox = try makeSandbox()
        let absent = sandbox.root.appendingPathComponent("nope", isDirectory: true)
        let scanner = SupermuxClaudeUsageLogScanner(
            projectsDirectory: absent,
            cacheStore: sandbox.cache,
            calendar: calendar
        )
        #expect(!scanner.isAvailable)
        #expect(scanner.scan().isEmpty)
    }

    @Test func malformedLinesDoNotAbortTheFile() throws {
        let sandbox = try makeSandbox()
        _ = try write([
            #"{"type":"assistant","message":{"id":"broken""#,
            "not json at all",
            assistantLine(id: "msg_ok", output: 12),
        ], to: sandbox.projects)

        let entries = scanner(projects: sandbox.projects, cache: sandbox.cache).scan()
        #expect(entries.first?.tokens.output == 12)
    }

    /// An empty walk almost always means the directory went missing, not that
    /// the history did. Overwriting the cache with the empty result destroyed
    /// a scan that cost minutes and could not be rebuilt.
    @Test func anEmptyWalkLeavesThePreviousCacheIntact() throws {
        let sandbox = try makeSandbox()
        let url = try write([assistantLine(id: "msg_1", output: 100)], to: sandbox.projects)
        let scanner = scanner(projects: sandbox.projects, cache: sandbox.cache)
        #expect(scanner.scan().first?.tokens.output == 100)

        // Simulate the directory disappearing (unmounted volume, revoked
        // permission) rather than the user deleting their history.
        try FileManager.default.removeItem(at: url)
        #expect(scanner.scan().isEmpty)

        // Restoring the file must not require a full cold reparse of history
        // the cache already held for every *other* file.
        let reloaded = SupermuxUsageAnalyticsCache(files: sandbox.cache.load(.claudeCode).files)
        #expect(reloaded.files.count == 1)
    }

    /// Progress has to reach `scanned == total` even when the final files are
    /// all skipped, or the popover's bar freezes short of full.
    @Test func progressReachesTotalWhenTrailingFilesAreSkipped() throws {
        let sandbox = try makeSandbox()
        _ = try write([assistantLine(id: "msg_0", output: 10)], to: sandbox.projects, named: "a.jsonl")
        // Two files whose mtime is far outside the scan window: both are
        // skipped, and the last one used to publish nothing at all.
        for name in ["y.jsonl", "z.jsonl"] {
            let old = try write([assistantLine(id: "old-\(name)", output: 5)], to: sandbox.projects, named: name)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-200 * 24 * 60 * 60)],
                ofItemAtPath: old.path
            )
        }

        let observed = ProgressRecorder()
        _ = scanner(projects: sandbox.projects, cache: sandbox.cache).scan { scanned, total, _ in
            observed.record(scanned: scanned, total: total)
        }
        #expect(observed.lastTotal == 3)
        #expect(observed.lastScanned == 3)
    }

    @Test func reportsProgressWhileScanning() throws {
        let sandbox = try makeSandbox()
        for index in 0..<3 {
            _ = try write([assistantLine(id: "msg_\(index)", output: 10)], to: sandbox.projects, named: "s\(index).jsonl")
        }
        let observed = ProgressRecorder()
        _ = scanner(projects: sandbox.projects, cache: sandbox.cache).scan { scanned, total, _ in
            observed.record(scanned: scanned, total: total)
        }
        #expect(observed.lastTotal == 3)
        #expect(observed.lastScanned == 3)
    }
}

/// Collects progress callbacks from the scanner's synchronous scan.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastScanned = 0
    private(set) var lastTotal = 0

    func record(scanned: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastScanned = scanned
        lastTotal = total
    }
}

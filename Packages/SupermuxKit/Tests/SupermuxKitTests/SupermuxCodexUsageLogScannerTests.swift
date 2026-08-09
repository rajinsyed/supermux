import Foundation
import Testing
@testable import SupermuxKit

@Suite
struct SupermuxCodexUsageLogScannerTests {
    @Test func cumulativeDeltasDoNotSumRepeatedLastUsage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":4,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":4,"total_tokens":110}}}}
            {"timestamp":"2026-08-04T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":15,"reasoning_output_tokens":6,"total_tokens":165},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":55}}}}
            {"timestamp":"2026-08-04T10:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":15,"reasoning_output_tokens":6,"total_tokens":165},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":55}}}}
            """.utf8),
            to: "sessions/2026/08/04/rollout-deltas.jsonl",
            under: root
        )

        let entries = scanner(root: root).scan()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.model == "gpt-5.6-sol")
        #expect(entry.tokens == SupermuxTokenCounts(
            uncachedInput: 120,
            cacheWrite: 0,
            cacheRead: 30,
            output: 15,
            reasoningOutput: 6
        ))
        #expect(entry.tokens.total == 165)
    }

    @Test func nullInfoIsSkippedWithoutResettingTheCumulativeBaseline() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":1,"reasoning_output_tokens":0}}}}
            {"timestamp":"2026-08-04T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex"}}}
            {"timestamp":"2026-08-04T10:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":15,"cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":0}}}}
            """.utf8),
            to: "sessions/2026/08/04/rollout-null-info.jsonl",
            under: root
        )

        let entry = try #require(scanner(root: root).scan().first)
        #expect(entry.tokens == SupermuxTokenCounts(
            uncachedInput: 12,
            cacheWrite: 0,
            cacheRead: 3,
            output: 2,
            reasoningOutput: 0
        ))
    }

    @Test func missingCacheWriteDefaultsToZero() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":5,"reasoning_output_tokens":1}}}}
            """.utf8),
            to: "sessions/2026/08/04/rollout-no-cache-write.jsonl",
            under: root
        )

        let entry = try #require(scanner(root: root).scan().first)
        #expect(entry.tokens.uncachedInput == 60)
        #expect(entry.tokens.cacheRead == 40)
        #expect(entry.tokens.cacheWrite == 0)
    }

    @Test func cacheWriteIsCarvedOutOfWholePromptInput() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":30,"output_tokens":5,"reasoning_output_tokens":1}}}}
            """.utf8),
            to: "sessions/2026/08/04/rollout-cache-write.jsonl",
            under: root
        )

        let entry = try #require(scanner(root: root).scan().first)
        #expect(entry.tokens == SupermuxTokenCounts(
            uncachedInput: 50,
            cacheWrite: 30,
            cacheRead: 20,
            output: 5,
            reasoningOutput: 1
        ))
    }

    @Test func precedingTurnContextControlsModelAndModelSwitchesReattributeDeltas() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-model-a"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}}}
            {"timestamp":"2026-08-04T10:02:00.000Z","type":"turn_context","payload":{"collaboration_mode":{"settings":{"model":"gpt-model-b"}}}}
            {"timestamp":"2026-08-04T10:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":25,"cached_input_tokens":5,"output_tokens":3,"reasoning_output_tokens":1}}}}
            """.utf8),
            to: "sessions/2026/08/04/rollout-model-switch.jsonl",
            under: root
        )

        let entries = scanner(root: root).scan()
        let first = try #require(entries.first { $0.model == "gpt-model-a" })
        let second = try #require(entries.first { $0.model == "gpt-model-b" })
        #expect(entries.count == 2)
        #expect(first.tokens == SupermuxTokenCounts(
            uncachedInput: 10,
            cacheWrite: 0,
            cacheRead: 0,
            output: 1,
            reasoningOutput: 0
        ))
        #expect(second.tokens == SupermuxTokenCounts(
            uncachedInput: 10,
            cacheWrite: 0,
            cacheRead: 5,
            output: 2,
            reasoningOutput: 1
        ))
    }

    @Test func negativeComponentDeltasAreClampedToZero() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":10}}}}
            {"timestamp":"2026-08-04T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":3,"reasoning_output_tokens":1}}}}
            {"timestamp":"2026-08-04T10:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"cached_input_tokens":7,"output_tokens":5,"reasoning_output_tokens":2}}}}
            """.utf8),
            to: "sessions/2026/08/04/rollout-reset.jsonl",
            under: root
        )

        let entry = try #require(scanner(root: root).scan().first)
        #expect(entry.tokens == SupermuxTokenCounts(
            uncachedInput: 68,
            cacheWrite: 0,
            cacheRead: 42,
            output: 22,
            reasoningOutput: 11
        ))
    }

    @Test func timestampsBucketIntoTheInjectedLocalCalendarDay() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeZone = try #require(TimeZone(secondsFromGMT: -8 * 60 * 60))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        try write(
            Data("""
            {"timestamp":"2026-01-02T02:30:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-01-02T02:31:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}}}
            {"timestamp":"2026-01-02T10:31:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":0}}}}
            """.utf8),
            to: "sessions/2026/01/02/rollout-local-days.jsonl",
            under: root
        )

        let entries = scanner(root: root, calendar: calendar).scan()
        let januaryFirst = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let januarySecond = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2)))
        #expect(entries.map(\.day) == [januaryFirst, januarySecond])
        #expect(entries.map(\.tokens.total) == [11, 11])
    }

    @Test func unchangedFileReusesItsCachedWholeFileContribution() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = "sessions/2026/08/04/rollout-cache.jsonl"
        let original = Data("""
        {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}}}
        """.utf8)
        let replacement = Data("""
        {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}}}
        """.utf8)
        #expect(original.count == replacement.count)
        let file = try write(original, to: relativePath, under: root)
        let fixedModificationDate = Date(timeIntervalSince1970: 1_780_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate],
            ofItemAtPath: file.path
        )

        let first = scanner(root: root).scan()
        #expect(first.first?.tokens.uncachedInput == 10)
        try replacement.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate],
            ofItemAtPath: file.path
        )

        let second = scanner(root: root).scan()
        #expect(second.first?.tokens.uncachedInput == 10)
    }

    @Test func flatArchivedSessionsAreIncluded() throws {
        let root = try makeRoot(createSessionsDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-archived"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"cached_input_tokens":2,"output_tokens":1,"reasoning_output_tokens":0}}}}
            """.utf8),
            to: "archived_sessions/rollout-archived.jsonl",
            under: root
        )

        let scanner = scanner(root: root)
        #expect(scanner.isAvailable)
        let entry = try #require(scanner.scan().first)
        #expect(entry.model == "gpt-archived")
        #expect(entry.tokens.total == 8)
    }

    @Test func usageWithoutTurnContextUsesUnknownModel() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}}}
            """.utf8),
            to: "sessions/2026/08/04/rollout-no-context.jsonl",
            under: root
        )

        let entry = try #require(scanner(root: root).scan().first)
        #expect(entry.model == "unknown")
        #expect(entry.tokens.total == 8)
    }

    /// `rolloutFiles()` reads `archived_sessions` too, so a user whose current
    /// sessions were all archived still has data. Reporting Codex as "no logs
    /// found" while its rows render contradicted the popover's own footer.
    @Test func archivedOnlyInstallIsStillAvailable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            Data("""
            {"timestamp":"2026-08-04T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-archived"}}
            {"timestamp":"2026-08-04T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"cached_input_tokens":2,"output_tokens":1,"reasoning_output_tokens":0}}}}
            """.utf8),
            to: "archived_sessions/rollout-archived-only.jsonl",
            under: root
        )

        let scanner = scanner(root: root)
        #expect(scanner.isAvailable)
        #expect(scanner.scan().first?.model == "gpt-archived")
    }

    @Test func missingSessionsDirectoryIsUnavailableAndYieldsNoEntries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = scanner(root: root)
        #expect(!scanner.isAvailable)
        #expect(scanner.scan().isEmpty)
    }

    private func scanner(
        root: URL,
        calendar: Calendar = Self.utcCalendar
    ) -> SupermuxCodexUsageLogScanner {
        SupermuxCodexUsageLogScanner(
            sessionsDirectory: root,
            cacheStore: SupermuxUsageAnalyticsCacheStore(
                directory: root.appendingPathComponent("cache", isDirectory: true)
            ),
            calendar: calendar
        )
    }

    private func makeRoot(createSessionsDirectory: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SupermuxCodexUsageLogScannerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createSessionsDirectory {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sessions", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    @discardableResult
    private func write(_ data: Data, to relativePath: String, under root: URL) throws -> URL {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file)
        return file
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

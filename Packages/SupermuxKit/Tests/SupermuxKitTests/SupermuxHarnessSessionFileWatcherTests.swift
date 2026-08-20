import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
@MainActor
struct SupermuxHarnessSessionFileWatcherTests {
    @Test func reportsAppendsAndSurvivesLateFileCreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")

        var changes = 0
        let watcher = SupermuxHarnessSessionFileWatcher(
            fileURL: file,
            debounce: .milliseconds(40)
        ) {
            changes += 1
        }
        defer { watcher.cancel() }

        // File does not exist yet: the retry loop must attach after creation.
        try "{\"type\":\"user\"}\n".write(to: file, atomically: false, encoding: .utf8)
        try await waitUntil { changes >= 1 }

        let observed = changes
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"ai-title\",\"aiTitle\":\"T\"}\n".utf8))
        try await waitUntil { changes > observed }
    }

    @Test func cancelSuppressesAnAlreadyScheduledReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try "seed\n".write(to: file, atomically: false, encoding: .utf8)

        var changes = 0
        var scheduledReport: (@MainActor () -> Void)?
        let watcher = SupermuxHarnessSessionFileWatcher(
            fileURL: file,
            debounce: .milliseconds(20),
            debounceScheduler: { _, report in
                scheduledReport = report
                return {}
            }
        ) {
            changes += 1
        }
        let report = try #require(scheduledReport)

        watcher.cancel()
        // A dispatch callback already queued before cancellation can still be
        // invoked by its executor; the watcher's cancellation guard must drop it.
        report()
        #expect(changes == 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for watcher callback")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

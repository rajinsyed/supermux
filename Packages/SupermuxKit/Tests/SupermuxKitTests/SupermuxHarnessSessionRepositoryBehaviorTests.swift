import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessSessionRepositoryBehaviorTests {
    @Test func repositoryMatchesLegacyListTitleAndHistorySemantics() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "legacy-parity")
        defer { sandbox.remove() }
        let directory = try sandbox.firstProjectDirectory()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try sandbox.writeSession(
            id: "complex",
            records: [
                [
                    "type": "user",
                    "uuid": "u1",
                    "parentUuid": NSNull(),
                    "cwd": sandbox.workingDirectoryURL.path,
                    "gitBranch": "main",
                    "message": ["role": "user", "content": "First prompt"],
                ],
                [
                    "type": "attachment",
                    "uuid": "bridge",
                    "parentUuid": "u1",
                    "attachment": ["type": "hook_success"],
                ],
                [
                    "type": "assistant",
                    "uuid": "a1",
                    "parentUuid": "bridge",
                    "gitBranch": "feature",
                    "effort": "high",
                    "message": ["role": "assistant", "content": "answer"],
                ],
                [
                    "type": "attachment",
                    "uuid": "queued-record",
                    "parentUuid": "a1",
                    "attachment": [
                        "type": "queued_command",
                        "commandMode": "prompt",
                        "prompt": "queued prompt",
                        "source_uuid": "queued-user",
                    ],
                ],
                [
                    "type": "assistant",
                    "uuid": "a2",
                    "parentUuid": "queued-record",
                    "message": ["role": "assistant", "content": "tail"],
                ],
                ["type": "summary", "summary": "Summary title", "leafUuid": "a1"],
                ["type": "ai-title", "aiTitle": "AI title"],
                ["type": "custom-title", "customTitle": "Custom title"],
                ["type": "last-prompt", "leafUuid": "a2"],
            ],
            modificationDate: date,
            directory: directory
        )
        _ = try sandbox.writeSession(
            id: "fallback",
            records: [["type": "queue-operation"]],
            modificationDate: date.addingTimeInterval(1),
            directory: directory
        )

        let discovery = sandbox.discovery()
        let expectedSessions = try discovery.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        let actualSessions = try await sandbox.repository.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        #expect(actualSessions == expectedSessions)
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "complex"
        ) == discovery.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "complex"
        ))
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "fallback"
        ) == nil)

        let expectedHistory = try discovery.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "complex",
            recordLimit: 3
        )
        let actualHistory = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "complex",
            recordLimit: 3
        )
        #expect(actualHistory == expectedHistory)
        #expect(actualHistory.events.compactMap { $0.string(forKey: "uuid") } == [
            "a1", "queued-user", "a2",
        ])
        #expect(actualHistory.truncated)
    }

    @Test func newestLimitFallsThroughFromMismatchedDuplicateToOlderMatch() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "supermux-harness-repository-limit-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let targetURL = rootURL.appendingPathComponent("target", isDirectory: true)
        let linkURL = rootURL.appendingPathComponent("link", isDirectory: true)
        let foreignURL = rootURL.appendingPathComponent("foreign", isDirectory: true)
        let projectsURL = rootURL.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsURL,
            fileManager: .default
        )
        let candidateDirectories = discovery.projectDirectoryURLs(for: linkURL)
        #expect(candidateDirectories.count == 2)
        for directory in candidateDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let repository = SupermuxHarnessSessionRepository(
            projectsRootURL: projectsURL,
            fileManager: .default,
            configuration: .production
        )
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let winnerURL = try writeSession(
            id: "winner",
            directory: candidateDirectories[0],
            records: [[
                "type": "user",
                "uuid": "winner-u",
                "cwd": targetURL.path,
                "message": ["role": "user", "content": "winner"],
            ]],
            modificationDate: baseDate.addingTimeInterval(40)
        )
        let newerForeignDuplicateURL = try writeSession(
            id: "duplicate",
            directory: candidateDirectories[1],
            records: [[
                "type": "user",
                "uuid": "foreign-u",
                "cwd": foreignURL.path,
                "message": ["role": "user", "content": "foreign"],
            ]],
            modificationDate: baseDate.addingTimeInterval(30)
        )
        let olderMatchingDuplicateURL = try writeSession(
            id: "duplicate",
            directory: candidateDirectories[0],
            records: [[
                "type": "user",
                "uuid": "matching-u",
                "cwd": targetURL.path,
                "message": ["role": "user", "content": "matching"],
            ]],
            modificationDate: baseDate.addingTimeInterval(20)
        )
        let beyondLimitURL = try writeSession(
            id: "beyond-limit",
            directory: candidateDirectories[0],
            records: [[
                "type": "user",
                "uuid": "old-u",
                "cwd": targetURL.path,
                "message": ["role": "user", "content": "old"],
            ]],
            modificationDate: baseDate.addingTimeInterval(10)
        )

        let sessions = try await repository.listSessions(for: linkURL, limit: 2)

        #expect(sessions.map(\.sessionID) == ["winner", "duplicate"])
        #expect(sessions.last?.firstPrompt == "matching")
        #expect(await repository.debugMetrics(for: winnerURL).scanCount == 1)
        #expect(await repository.debugMetrics(for: newerForeignDuplicateURL).scanCount == 1)
        #expect(await repository.debugMetrics(for: olderMatchingDuplicateURL).scanCount == 1)
        #expect(await repository.debugMetrics(for: beyondLimitURL).scanCount == 0)
    }

    @Test func historyIndexesOnceThenReadsOnlySelectedRecordRanges() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "history-one-pass")
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: [
            ["type": "user", "uuid": "u1", "parentUuid": NSNull(), "message": ["role": "user", "content": "one"]],
            ["type": "attachment", "uuid": "bridge", "parentUuid": "u1", "attachment": ["type": "hook_success"]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "bridge", "message": ["role": "assistant", "content": "two"]],
            ["type": "assistant", "uuid": "side", "parentUuid": "a1", "isSidechain": true, "message": ["role": "assistant", "content": "hidden"]],
            ["type": "user", "uuid": "u2", "parentUuid": "side", "message": ["role": "user", "content": "three"]],
            ["type": "summary", "summary": "Summary", "leafUuid": "u2"],
            ["type": "last-prompt", "leafUuid": "u2"],
        ])

        let first = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "session",
            recordLimit: nil
        )
        let afterFirst = await sandbox.repository.debugMetrics(for: fileURL)
        let second = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "session",
            recordLimit: nil
        )
        let afterSecond = await sandbox.repository.debugMetrics(for: fileURL)

        #expect(first.events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a1", "u2"])
        #expect(second == first)
        #expect(afterFirst.scanCount == 1)
        #expect(afterFirst.indexedRecordCount == 7)
        #expect(afterFirst.selectedRecordReadCount == 3)
        #expect(afterFirst.selectedRecordBytesRead < afterFirst.indexBytesRead)
        #expect(afterSecond.scanCount == 1)
        #expect(afterSecond.indexedRecordCount == 7)
        #expect(afterSecond.selectedRecordReadCount == 6)
        #expect(afterSecond.indexBytesRead == afterFirst.indexBytesRead)
    }

    @Test func historyPreservesVisibleRecordLimitAndSafetyErrors() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "history-cap")
        defer { sandbox.remove() }
        var records: [[String: Any]] = []
        for index in 0..<405 {
            var record: [String: Any] = [
                "type": index.isMultiple(of: 2) ? "user" : "assistant",
                "uuid": "record-\(index)",
                "message": [
                    "role": index.isMultiple(of: 2) ? "user" : "assistant",
                    "content": "\(index)",
                ],
            ]
            if index > 0 {
                record["parentUuid"] = "record-\(index - 1)"
            }
            records.append(record)
        }
        _ = try sandbox.writeSession(id: "session", records: records)

        let page = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "session",
            recordLimit: 400
        )

        #expect(page.truncated)
        #expect(page.events.count == 400)
        #expect(page.events.first?.string(forKey: "uuid") == "record-5")
        #expect(page.events.last?.string(forKey: "uuid") == "record-404")
        await #expect(throws: SupermuxHarnessSessionDiscoveryError.invalidSessionID) {
            _ = try await sandbox.repository.loadHistory(
                for: sandbox.workingDirectoryURL,
                sessionID: "../escape",
                recordLimit: nil
            )
        }
        await #expect(throws: SupermuxHarnessSessionDiscoveryError.sessionNotFound("missing")) {
            _ = try await sandbox.repository.loadHistory(
                for: sandbox.workingDirectoryURL,
                sessionID: "missing",
                recordLimit: nil
            )
        }
    }

    @discardableResult
    private func writeSession(
        id: String,
        directory: URL,
        records: [[String: Any]],
        modificationDate: Date
    ) throws -> URL {
        let fileURL = directory.appendingPathComponent(id).appendingPathExtension("jsonl")
        try SupermuxHarnessSessionRepositorySandbox.jsonlData(records: records)
            .write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }
}

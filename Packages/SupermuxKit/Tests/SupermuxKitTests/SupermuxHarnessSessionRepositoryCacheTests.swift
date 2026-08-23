import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessSessionRepositoryCacheTests {
    @Test func metadataListAndTitleWarmReadsShareOneIncrementalScan() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "warm")
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: [
            ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "Prompt"]],
            ["type": "ai-title", "aiTitle": "Warm title"],
        ])

        let first = try await sandbox.repository.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        let afterColdRead = await sandbox.repository.debugMetrics(for: fileURL)
        let second = try await sandbox.repository.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        let title = await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        )
        let afterWarmReads = await sandbox.repository.debugMetrics(for: fileURL)

        #expect(first == second)
        #expect(title == "Warm title")
        #expect(afterColdRead.scanCount == 1)
        #expect(afterWarmReads.scanCount == 1)
        #expect(afterWarmReads.indexBytesRead == afterColdRead.indexBytesRead)
        #expect(afterWarmReads.indexedRecordCount == afterColdRead.indexedRecordCount)
        #expect(afterWarmReads.readOffsets == [0])
        let cache = await sandbox.repository.debugCacheMetrics()
        #expect(cache.metadataEntryCount == 1)
        #expect(cache.historyEntryCount == 0)
    }

    @Test func appendValidationResumesAtPriorObservedSizeAndUpdatesHistoryIncrementally() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "append-offset")
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: [
            ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "First"]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "u1", "message": ["role": "assistant", "content": "Answer"]],
            ["type": "ai-title", "aiTitle": "First title"],
        ])
        let originalSize = try #require(
            (try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize
        )

        let firstHistory = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "session",
            recordLimit: nil
        )
        #expect(firstHistory.events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a1"])
        var append = try SupermuxHarnessSessionRepositorySandbox.jsonLine([
            "type": "user",
            "uuid": "u2",
            "parentUuid": "a1",
            "message": ["role": "user", "content": "Second"],
        ])
        append.append(try SupermuxHarnessSessionRepositorySandbox.jsonLine([
            "type": "ai-title",
            "aiTitle": "Second title",
        ]))
        try sandbox.append(append, to: fileURL)

        let secondHistory = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "session",
            recordLimit: nil
        )
        let title = await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        )
        let metrics = await sandbox.repository.debugMetrics(for: fileURL)

        #expect(secondHistory.events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a1", "u2"])
        #expect(title == "Second title")
        #expect(metrics.scanCount == 2)
        #expect(metrics.readOffsets == [0, UInt64(originalSize)])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let currentSize = try #require(attributes[.size] as? NSNumber).uint64Value
        #expect(metrics.indexBytesRead == currentSize)
    }

    @Test func unterminatedAndOverlongTailsStayProvisionalAcrossAppends() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "tails")
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: [])
        let partial = Data("{\"aiTitle\":\"Partial".utf8)
        try sandbox.rewriteInPlace(partial, at: fileURL)

        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == nil)
        try sandbox.append(Data(" title\",\"type\":\"ai-title\"}\n".utf8), to: fileURL)
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Partial title")

        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: SupermuxLineReader.maximumLineBytes + 1
        )
        try sandbox.append(oversized, to: fileURL)
        let skipped = try await sandbox.repository.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        #expect(skipped.first?.messageCount == 0)
        var recovery = Data("\n".utf8)
        recovery.append(try SupermuxHarnessSessionRepositorySandbox.jsonLine([
            "type": "user",
            "uuid": "kept",
            "message": ["role": "user", "content": "kept"],
        ]))
        try sandbox.append(recovery, to: fileURL)

        let recovered = try await sandbox.repository.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        #expect(recovered.first?.messageCount == 1)
        #expect(recovered.first?.firstPrompt == "kept")
    }

    @Test func sameInodeTruncateRewriteAndGrowCannotMasqueradeAsAppend() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "same-inode-rewrite")
        defer { sandbox.remove() }
        let commonTail = [
            "type": "queue-operation",
            "padding": String(repeating: "z", count: 4_096),
        ]
        let fileURL = try sandbox.writeSession(id: "session", records: [
            ["type": "ai-title", "aiTitle": "Alpha"],
            commonTail,
        ])
        let originalSize = try #require(
            (try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize
        )
        let originalInode = try sandbox.inode(of: fileURL)
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Alpha")

        let rewritten = try SupermuxHarnessSessionRepositorySandbox.jsonlData(records: [
            ["type": "ai-title", "aiTitle": "Bravo"],
            commonTail,
            [
                "type": "user",
                "uuid": "new-user",
                "message": [
                    "role": "user",
                    "content": String(repeating: "new", count: 2_000),
                ],
            ],
        ])
        #expect(rewritten.count > originalSize)
        try sandbox.rewriteInPlace(rewritten, at: fileURL)
        #expect(try sandbox.inode(of: fileURL) == originalInode)

        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Bravo")
        let sessions = try await sandbox.repository.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        #expect(sessions.first?.messageCount == 1)
        #expect(sessions.first?.firstPrompt == String(repeating: "new", count: 2_000))
        let metrics = await sandbox.repository.debugMetrics(for: fileURL)
        #expect(metrics.scanCount == 2)
        #expect(metrics.readOffsets == [0, 0])
    }

    @Test func truncationSameSizeRewriteAndPathReplacementResetCachedState() async throws {
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(name: "invalidations")
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: [
            ["type": "ai-title", "aiTitle": "Original long title"],
            ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "one"]],
        ])
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Original long title")

        try sandbox.rewriteInPlace(
            try SupermuxHarnessSessionRepositorySandbox.jsonLine([
                "type": "ai-title",
                "aiTitle": "Short",
            ]),
            at: fileURL
        )
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Short")

        let sameSizeOld = try SupermuxHarnessSessionRepositorySandbox.jsonLine([
            "type": "ai-title",
            "aiTitle": "Alpha",
        ])
        let sameSizeNew = try SupermuxHarnessSessionRepositorySandbox.jsonLine([
            "type": "ai-title",
            "aiTitle": "Bravo",
        ])
        #expect(sameSizeOld.count == sameSizeNew.count)
        try sandbox.rewriteInPlace(sameSizeOld, at: fileURL)
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Alpha")
        try sandbox.rewriteInPlace(sameSizeNew, at: fileURL)
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Bravo")

        try sandbox.replace(
            try SupermuxHarnessSessionRepositorySandbox.jsonLine([
                "type": "ai-title",
                "aiTitle": "Replacement",
            ]),
            at: fileURL
        )
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        ) == "Replacement")
        #expect(await sandbox.repository.debugMetrics(for: fileURL).readOffsets == [0, 0, 0, 0, 0])
    }

    @Test func metadataAndHistoryEntryLRUsEvictIndependently() async throws {
        var configuration = SupermuxHarnessSessionRepositoryConfiguration.production
        configuration.metadataMaximumEntries = 3
        configuration.historyMaximumEntries = 1
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(
            name: "entry-lru",
            configuration: configuration
        )
        defer { sandbox.remove() }
        let oneURL = try sandbox.writeSession(id: "one", records: chain(title: "One"))
        let twoURL = try sandbox.writeSession(id: "two", records: chain(title: "Two"))
        let threeURL = try sandbox.writeSession(id: "three", records: chain(title: "Three"))

        _ = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "one",
            recordLimit: nil
        )
        _ = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "two",
            recordLimit: nil
        )
        #expect(await sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "one"
        ) == "One")
        _ = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "three",
            recordLimit: nil
        )
        let beforeReload = await sandbox.repository.debugCacheMetrics()
        #expect(beforeReload.metadataEntryCount == 3)
        #expect(beforeReload.historyEntryCount == 1)

        _ = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "one",
            recordLimit: nil
        )
        #expect(await sandbox.repository.debugMetrics(for: oneURL).scanCount == 2)
        #expect(await sandbox.repository.debugMetrics(for: twoURL).scanCount == 1)
        #expect(await sandbox.repository.debugMetrics(for: threeURL).scanCount == 1)
        let afterReload = await sandbox.repository.debugCacheMetrics()
        #expect(afterReload.metadataEntryCount == 3)
        #expect(afterReload.historyEntryCount == 1)
    }

    @Test func metadataAndHistoryByteBoundsEvictOversizedEntries() async throws {
        var configuration = SupermuxHarnessSessionRepositoryConfiguration.production
        configuration.metadataMaximumEntries = 20
        configuration.metadataMaximumBytes = 512
        configuration.historyMaximumEntries = 20
        configuration.historyMaximumBytes = 1_024
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(
            name: "byte-lru",
            configuration: configuration
        )
        defer { sandbox.remove() }
        let largeText = String(repeating: "payload", count: 1_000)
        let fileURL = try sandbox.writeSession(id: "large", records: [
            ["type": "user", "uuid": "u1", "message": ["role": "user", "content": largeText]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "u1", "message": ["role": "assistant", "content": largeText]],
            ["type": "ai-title", "aiTitle": largeText],
        ])

        _ = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "large",
            recordLimit: nil
        )
        let cache = await sandbox.repository.debugCacheMetrics()
        #expect(cache.metadataByteCount <= configuration.metadataMaximumBytes)
        #expect(cache.historyByteCount <= configuration.historyMaximumBytes)
        _ = try await sandbox.repository.loadHistory(
            for: sandbox.workingDirectoryURL,
            sessionID: "large",
            recordLimit: nil
        )
        #expect(await sandbox.repository.debugMetrics(for: fileURL).scanCount == 2)
    }

    @Test func physicalReadsStayWithinTheConfiguredChunkBound() async throws {
        var configuration = SupermuxHarnessSessionRepositoryConfiguration.production
        configuration.readChunkBytes = 257
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(
            name: "chunk-bound",
            configuration: configuration
        )
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: (0..<200).map { index in
            [
                "type": "user",
                "uuid": "u-\(index)",
                "message": ["role": "user", "content": String(repeating: "x", count: 80)],
            ]
        })

        _ = try await sandbox.repository.listSessions(
            for: sandbox.workingDirectoryURL,
            limit: nil
        )
        let metrics = await sandbox.repository.debugMetrics(for: fileURL)
        #expect(metrics.maximumReadChunkBytes > 0)
        #expect(metrics.maximumReadChunkBytes <= configuration.readChunkBytes)
    }

    private func chain(title: String) -> [[String: Any]] {
        [
            ["type": "user", "uuid": "u", "message": ["role": "user", "content": title]],
            ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": "answer"]],
            ["type": "ai-title", "aiTitle": title],
        ]
    }
}

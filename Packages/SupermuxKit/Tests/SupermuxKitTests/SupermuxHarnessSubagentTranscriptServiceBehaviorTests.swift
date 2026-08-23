import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessSubagentTranscriptServiceBehaviorTests {
    @Test func revisionsDistinguishInitialAppendUnchangedAndFreshConsumers() async throws {
        let sandbox = try makeSandbox(named: "revisions")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let missing = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        #expect(missing.revision == 1)
        #expect(missing.replace)
        #expect(missing.missing)
        #expect(missing.metadata == .deleted)

        let unchangedMissing = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: missing.revision
        )
        #expect(unchangedMissing.revision == missing.revision)
        #expect(!unchangedMissing.replace)
        #expect(unchangedMissing.events.isEmpty)
        #expect(unchangedMissing.metadata == .unchanged)

        try sandbox.createTranscriptDirectory()
        try sandbox.write([assistantLine(uuid: "event-1", text: "alpha")])
        let appeared = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: missing.revision
        )
        #expect(appeared.revision == missing.revision + 1)
        #expect(appeared.replace)
        #expect(!appeared.missing)
        #expect(eventIDs(appeared) == ["event-1"])

        try sandbox.append([assistantLine(uuid: "event-2", text: "beta")])
        let appended = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: appeared.revision
        )
        #expect(appended.revision == appeared.revision + 1)
        #expect(!appended.replace)
        #expect(appended.droppedEventCount == 0)
        #expect(eventIDs(appended) == ["event-2"])

        let unchanged = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: appended.revision
        )
        #expect(unchanged.revision == appended.revision)
        #expect(!unchanged.replace)
        #expect(unchanged.events.isEmpty)
        #expect(unchanged.metadata == .unchanged)

        let freshConsumer = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: nil
        )
        #expect(freshConsumer.revision == appended.revision)
        #expect(freshConsumer.replace)
        #expect(eventIDs(freshConsumer) == ["event-1", "event-2"])
    }

    @Test func symlinkedWorkingDirectoryFindsLexicalProjectStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-subagent-symlink-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let realWorking = root.appendingPathComponent("real-working", isDirectory: true)
        let linkedWorking = root.appendingPathComponent("linked-working", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realWorking, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedWorking, withDestinationURL: realWorking)
        defer { try? FileManager.default.removeItem(at: root) }

        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        let names = discovery.mungedProjectDirectoryNames(for: linkedWorking)
        let lexicalName = try #require(names.last)
        let transcriptDirectory = projects
            .appendingPathComponent(lexicalName, isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try (assistantLine(uuid: "event-1", text: "lexical transcript") + "\n")
            .write(
                to: transcriptDirectory.appendingPathComponent("agent-task.jsonl"),
                atomically: false,
                encoding: .utf8
            )
        let service = SupermuxHarnessSubagentTranscriptService(
            projectsRootURL: projects,
            fileManager: .default
        )

        let update = try await service.loadTranscript(
            at: .localAgent(
                workingDirectoryURL: linkedWorking,
                sessionID: "session",
                taskID: "task"
            ),
            afterRevision: nil
        )

        #expect(!update.missing)
        #expect(eventIDs(update) == ["event-1"])
    }

    @Test func laggingConsumersReceiveAReconciliableDeltaOrReplacement() async throws {
        let sandbox = try makeSandbox(named: "consumer-reconciliation")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        try sandbox.write([assistantLine(uuid: "event-1", text: "one")])
        let first = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)

        try sandbox.append([assistantLine(uuid: "event-2", text: "two")])
        let second = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: first.revision
        )
        let secondConsumer = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: first.revision
        )
        #expect(!secondConsumer.replace)
        #expect(secondConsumer.revision == second.revision)
        #expect(eventIDs(secondConsumer) == ["event-2"])

        try sandbox.append([assistantLine(uuid: "event-3", text: "three")])
        let third = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: second.revision
        )
        let staleConsumer = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: first.revision
        )
        #expect(staleConsumer.replace)
        #expect(staleConsumer.revision == third.revision)
        #expect(eventIDs(staleConsumer) == ["event-1", "event-2", "event-3"])
    }

    @Test func rewriteTruncateReplacementAndDeletionNeverMasqueradeAsAppend() async throws {
        let sandbox = try makeSandbox(named: "replacement")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()

        let original = assistantLine(uuid: "event-a", text: "alpha")
        let rewritten = assistantLine(uuid: "event-b", text: "bravo")
        #expect(original.utf8.count == rewritten.utf8.count)
        try sandbox.write([original])
        let initial = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)

        try sandbox.write([rewritten])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: sandbox.transcriptURL.path
        )
        let sameLength = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: initial.revision
        )
        #expect(sameLength.replace)
        #expect(eventIDs(sameLength) == ["event-b"])

        try sandbox.append([assistantLine(uuid: "event-c", text: "charl")])
        let appended = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: sameLength.revision
        )
        #expect(!appended.replace)
        #expect(eventIDs(appended) == ["event-c"])

        try sandbox.write([rewritten])
        let truncated = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: appended.revision
        )
        #expect(truncated.replace)
        #expect(eventIDs(truncated) == ["event-b"])

        let replacement = assistantLine(uuid: "event-d", text: "delta")
        try Data((replacement + "\n").utf8).write(to: sandbox.transcriptURL, options: .atomic)
        let replacedFile = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: truncated.revision
        )
        #expect(replacedFile.replace)
        #expect(eventIDs(replacedFile) == ["event-d"])

        try FileManager.default.removeItem(at: sandbox.transcriptURL)
        let deleted = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: replacedFile.revision
        )
        #expect(deleted.replace)
        #expect(deleted.missing)
        #expect(deleted.events.isEmpty)
    }

    @Test func continuityCheckCatchesSameInodeRewriteThatGrowsPastOldEOF() async throws {
        let sandbox = try makeSandbox(named: "rewrite-grow")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        try sandbox.write([
            assistantLine(uuid: "old-1", text: "original one"),
            assistantLine(uuid: "old-2", text: "original two"),
        ])
        let initial = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        let before = try FileManager.default.attributesOfItem(atPath: sandbox.transcriptURL.path)
        let inode = (before[.systemFileNumber] as? NSNumber)?.uint64Value
        let byteCount = try #require((before[.size] as? NSNumber)?.uint64Value)

        let replacementLines = [
            assistantLine(uuid: "new-1", text: "replacement one"),
            assistantLine(uuid: "new-2", text: "replacement two"),
            assistantLine(uuid: "new-3", text: "replacement three"),
        ]
        let handle = try FileHandle(forWritingTo: sandbox.transcriptURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((replacementLines.joined(separator: "\n") + "\n").utf8))
        try handle.close()

        let after = try FileManager.default.attributesOfItem(atPath: sandbox.transcriptURL.path)
        #expect((after[.systemFileNumber] as? NSNumber)?.uint64Value == inode)
        #expect((after[.size] as? NSNumber)?.uint64Value ?? 0 > byteCount)

        let update = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: initial.revision
        )
        #expect(update.replace)
        #expect(eventIDs(update) == ["new-1", "new-2", "new-3"])
    }

    @Test func newestByteRetentionReportsOnlyTheDroppedPrefix() async throws {
        let lines = (1...3).map { assistantLine(uuid: "event-\($0)", text: "same") }
        #expect(lines[0].utf8.count == lines[1].utf8.count)
        #expect(lines[1].utf8.count == lines[2].utf8.count)
        let sandbox = try makeSandbox(
            named: "retention",
            maximumTranscriptBytes: lines[0].utf8.count + lines[1].utf8.count
        )
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        try sandbox.write(Array(lines.prefix(2)))

        let initial = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        #expect(!initial.truncated)
        #expect(eventIDs(initial) == ["event-1", "event-2"])

        try sandbox.append([lines[2]])
        let delta = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: initial.revision
        )
        #expect(!delta.replace)
        #expect(delta.truncated)
        #expect(delta.droppedEventCount == 1)
        #expect(eventIDs(delta) == ["event-3"])
    }

    @Test func metadataChangesAreRevisionedWithoutReplayingTranscriptEvents() async throws {
        let sandbox = try makeSandbox(named: "metadata")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        try sandbox.write([assistantLine(uuid: "event-1", text: "alpha")])
        try sandbox.writeMetadata([
            "agentType": "general-purpose",
            "description": "Inspect",
            "spawnDepth": 2,
        ])

        let initial = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        #expect(initial.metadata == .value(SupermuxHarnessSubagentTranscriptMetadata(
            agentType: "general-purpose",
            description: "Inspect",
            spawnDepth: 2
        )))

        try sandbox.writeMetadata([
            "agentType": "general-purpose",
            "description": "Inspect again",
            "spawnDepth": 2,
        ])
        let changed = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: initial.revision
        )
        #expect(changed.revision == initial.revision + 1)
        #expect(!changed.replace)
        #expect(changed.events.isEmpty)
        #expect(changed.metadata == .value(SupermuxHarnessSubagentTranscriptMetadata(
            agentType: "general-purpose",
            description: "Inspect again",
            spawnDepth: 2
        )))

        try FileManager.default.removeItem(at: sandbox.metadataURL)
        let deleted = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: changed.revision
        )
        #expect(!deleted.replace)
        #expect(deleted.events.isEmpty)
        #expect(deleted.metadata == .deleted)

        let unchanged = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: deleted.revision
        )
        #expect(unchanged.revision == deleted.revision)
        #expect(unchanged.metadata == .unchanged)
    }

    @Test func malformedLinesStaySkippedAndIncompleteJSONCompletesOnAppend() async throws {
        let sandbox = try makeSandbox(named: "split")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        let prefix = "{\"type\":\"assistant\",\"uuid\":\"event-2\",\"message\":{\"role\":\"assistant\",\"content\":\"split"
        try (assistantLine(uuid: "event-1", text: "alpha") + "\nnot-json\n" + prefix)
            .write(to: sandbox.transcriptURL, atomically: false, encoding: .utf8)

        let initial = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        #expect(eventIDs(initial) == ["event-1"])

        let handle = try FileHandle(forWritingTo: sandbox.transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\"}}\n".utf8))
        try handle.close()
        let completed = try await sandbox.service.loadTranscript(
            at: sandbox.address,
            afterRevision: initial.revision
        )
        #expect(!completed.replace)
        #expect(completed.droppedEventCount == 0)
        #expect(eventIDs(completed) == ["event-2"])
    }

    @Test func concurrentConsumersCoalesceAndOneDirtyRerunReadsTheLatestBytes() async throws {
        let scanGate = ScanGate()
        let sandbox = try makeSandbox(
            named: "single-flight",
            instrumentation: .init(
                didBeginRequest: { await scanGate.requestDidBegin() },
                willStartScan: { await scanGate.scanWillStart() }
            )
        )
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        try sandbox.write([assistantLine(uuid: "event-1", text: "one")])

        let first = Task {
            try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        }
        await scanGate.waitUntilFirstScanIsBlocked()
        try sandbox.append([assistantLine(uuid: "event-2", text: "two")])

        let followersReady = ReadinessGate(expected: 2)
        let second = Task {
            await followersReady.markReady()
            return try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        }
        let third = Task {
            await followersReady.markReady()
            return try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        }
        await followersReady.waitUntilReady()
        await scanGate.waitUntilRequestCount(3)
        await scanGate.releaseFirstScan()

        let updates = try await [first.value, second.value, third.value]
        let scanCount = await scanGate.startedScanCount()
        #expect(scanCount == 2)
        #expect(updates.allSatisfy { eventIDs($0) == ["event-1", "event-2"] })
        #expect(Set(updates.map(\.revision)).count == 1)
    }

    @Test func rewriteDuringAnAppendScanForcesTheDirtyRerunToStartFull() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-transcript-behavior-mid-scan-rewrite-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let working = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        let projectName = try #require(discovery.mungedProjectDirectoryNames(for: working).first)
        let transcriptDirectory = projects
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: transcriptDirectory,
            withIntermediateDirectories: true
        )
        let transcriptURL = transcriptDirectory.appendingPathComponent("agent-task.jsonl")
        let oldLines = (0..<300).map { index in
            assistantLine(uuid: "old-\(index)", text: String(repeating: "o", count: 64))
        }
        try (oldLines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: false, encoding: .utf8)
        let replacementLines = (0..<3_000).map { index in
            assistantLine(uuid: "new-\(index)", text: String(repeating: "n", count: 96))
        }
        let tracker = TranscriptMutationTracker(
            transcriptURL: transcriptURL,
            replacementData: Data((replacementLines.joined(separator: "\n") + "\n").utf8)
        )
        let service = SupermuxHarnessSubagentTranscriptService(
            projectsRootURL: projects,
            fileManager: .default,
            scanInstrumentation: .init(
                willStartScan: { tracker.recordScanStart() },
                willProcessChunk: { tracker.mutateWhenArmed() }
            )
        )
        let address = SupermuxHarnessSubagentTranscriptAddress.localAgent(
            workingDirectoryURL: working,
            sessionID: "session",
            taskID: "task"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let initial = try await service.loadTranscript(at: address, afterRevision: nil)
        let before = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let inode = (before[.systemFileNumber] as? NSNumber)?.uint64Value
        let appendHandle = try FileHandle(forWritingTo: transcriptURL)
        try appendHandle.seekToEnd()
        let appendedLines = (0..<2_000).map { index in
            assistantLine(uuid: "append-\(index)", text: String(repeating: "a", count: 64))
        }
        try appendHandle.write(contentsOf: Data((appendedLines.joined(separator: "\n") + "\n").utf8))
        try appendHandle.close()
        let grown = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let grownByteCount = try #require((grown[.size] as? NSNumber)?.uint64Value)
        tracker.arm()

        let update = try await service.loadTranscript(
            at: address,
            afterRevision: initial.revision
        )
        let after = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        #expect((after[.systemFileNumber] as? NSNumber)?.uint64Value == inode)
        #expect((after[.size] as? NSNumber)?.uint64Value ?? 0 > grownByteCount)
        #expect(tracker.scanStartCount == 3)
        #expect(update.replace)
        #expect(update.events.first?.string(forKey: "uuid") == "new-0")
        #expect(update.events.last?.string(forKey: "uuid") == "new-2999")
        #expect(!eventIDs(update).contains("old-0"))
    }

    @Test func scansUseBoundedChunksAndDrainEveryChunkPool() async throws {
        let tracker = ChunkTracker()
        let sandbox = try makeSandbox(
            named: "chunks",
            instrumentation: .init(
                willProcessChunk: { tracker.willProcessChunk() },
                didDrainChunk: { tracker.didDrainChunk() }
            )
        )
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        try sandbox.write((0..<12_000).map { index in
            assistantLine(uuid: "event-\(index)", text: String(repeating: "x", count: 96))
        })

        _ = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        let snapshot = tracker.snapshot()
        #expect(snapshot.processed > 1)
        #expect(snapshot.drained == snapshot.processed)
    }

    @Test func workflowAddressesUseTheirRunDirectoryAndPreservePathSafety() async throws {
        let sandbox = try makeSandbox(named: "workflow-path")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let workflowDirectory = sandbox.transcriptDirectory
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf-run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workflowDirectory,
            withIntermediateDirectories: true
        )
        let workflowURL = workflowDirectory.appendingPathComponent("agent-worker.jsonl")
        try sandbox.write(
            [assistantLine(uuid: "workflow-event", text: "answer")],
            to: workflowURL
        )
        let workflowAddress = SupermuxHarnessSubagentTranscriptAddress.workflowAgent(
            workingDirectoryURL: sandbox.working,
            sessionID: "session",
            workflowRunID: "wf-run",
            agentID: "worker"
        )

        let workflow = try await sandbox.service.loadTranscript(
            at: workflowAddress,
            afterRevision: nil
        )
        #expect(eventIDs(workflow) == ["workflow-event"])

        await #expect(throws: SupermuxHarnessSubagentTranscriptReaderError.invalidIdentifier) {
            try await sandbox.service.loadTranscript(
                at: .localAgent(
                    workingDirectoryURL: sandbox.working,
                    sessionID: "session",
                    taskID: "../escape"
                ),
                afterRevision: nil
            )
        }

        try sandbox.createTranscriptDirectory()
        let foreignDirectory = sandbox.root.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(
            at: foreignDirectory,
            withIntermediateDirectories: true
        )
        let foreignLine = "{\"type\":\"assistant\",\"uuid\":\"foreign\",\"cwd\":\"\(foreignDirectory.path)\",\"message\":{\"role\":\"assistant\",\"content\":\"private\"}}"
        try sandbox.write([foreignLine])
        await #expect(throws: SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath) {
            try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        }
    }

    @Test func overlongRecordsStayBoundedAndDoNotHideFollowingJSON() async throws {
        let sandbox = try makeSandbox(named: "overlong")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.createTranscriptDirectory()
        let overlong = String(repeating: "x", count: SupermuxLineReader.maximumLineBytes + 1)
        try sandbox.write([
            overlong,
            assistantLine(uuid: "after-overlong", text: "visible"),
        ])

        let update = try await sandbox.service.loadTranscript(at: sandbox.address, afterRevision: nil)
        #expect(eventIDs(update) == ["after-overlong"])
    }

    @Test func metadataMutationDuringAChunkTriggersOneStableRerun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-transcript-behavior-meta-dirty-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let working = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        let projectName = try #require(discovery.mungedProjectDirectoryNames(for: working).first)
        let transcriptDirectory = projects
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: transcriptDirectory,
            withIntermediateDirectories: true
        )
        let transcriptURL = transcriptDirectory.appendingPathComponent("agent-task.jsonl")
        let metadataURL = transcriptDirectory.appendingPathComponent("agent-task.meta.json")
        try (0..<2_000).map { index in
            assistantLine(uuid: "event-\(index)", text: String(repeating: "x", count: 48))
        }.joined(separator: "\n").appending("\n")
            .write(to: transcriptURL, atomically: false, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["description": "Before"])
            .write(to: metadataURL)
        let tracker = MetadataMutationTracker(metadataURL: metadataURL)
        let service = SupermuxHarnessSubagentTranscriptService(
            projectsRootURL: projects,
            fileManager: .default,
            scanInstrumentation: .init(
                willStartScan: { tracker.recordScanStart() },
                willProcessChunk: { tracker.mutateOnce() }
            )
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let update = try await service.loadTranscript(
            at: .localAgent(
                workingDirectoryURL: working,
                sessionID: "session",
                taskID: "task"
            ),
            afterRevision: nil
        )
        #expect(tracker.scanStartCount == 2)
        #expect(update.metadata == .value(SupermuxHarnessSubagentTranscriptMetadata(
            agentType: nil,
            description: "After",
            spawnDepth: nil
        )))
    }

    @Test func cacheEvictsByEntryCountAndByteCount() async throws {
        let byEntries = try makeSandbox(
            named: "lru-entries",
            maximumCachedEntries: 2,
            maximumCachedBytes: 1 << 20
        )
        defer { try? FileManager.default.removeItem(at: byEntries.root) }
        try byEntries.createTranscriptDirectory()
        for taskID in ["one", "two", "three"] {
            try byEntries.write(
                [assistantLine(uuid: taskID, text: "value")],
                to: byEntries.transcriptURL(taskID: taskID)
            )
            _ = try await byEntries.service.loadTranscript(
                at: byEntries.address(taskID: taskID),
                afterRevision: nil
            )
        }
        let entrySnapshot = await byEntries.service.cacheSnapshot()
        #expect(entrySnapshot.entryCount == 2)
        #expect(entrySnapshot.retainedByteCount > 0)
        #expect(entrySnapshot.retainedByteCount <= 1 << 20)

        let revisionAfterEviction = try makeSandbox(
            named: "lru-revision",
            maximumCachedEntries: 1,
            maximumCachedBytes: 1 << 20
        )
        defer { try? FileManager.default.removeItem(at: revisionAfterEviction.root) }
        try revisionAfterEviction.createTranscriptDirectory()
        try revisionAfterEviction.write(
            [assistantLine(uuid: "one", text: "value")],
            to: revisionAfterEviction.transcriptURL(taskID: "one")
        )
        try revisionAfterEviction.write(
            [assistantLine(uuid: "two", text: "value")],
            to: revisionAfterEviction.transcriptURL(taskID: "two")
        )
        let beforeEviction = try await revisionAfterEviction.service.loadTranscript(
            at: revisionAfterEviction.address(taskID: "one"),
            afterRevision: nil
        )
        _ = try await revisionAfterEviction.service.loadTranscript(
            at: revisionAfterEviction.address(taskID: "two"),
            afterRevision: nil
        )
        let afterEviction = try await revisionAfterEviction.service.loadTranscript(
            at: revisionAfterEviction.address(taskID: "one"),
            afterRevision: beforeEviction.revision
        )
        #expect(afterEviction.replace)
        #expect(afterEviction.revision > beforeEviction.revision)

        let byBytes = try makeSandbox(
            named: "lru-bytes",
            maximumCachedEntries: 10,
            maximumCachedBytes: 1
        )
        defer { try? FileManager.default.removeItem(at: byBytes.root) }
        try byBytes.createTranscriptDirectory()
        try byBytes.write([assistantLine(uuid: "large", text: "value")])
        _ = try await byBytes.service.loadTranscript(at: byBytes.address, afterRevision: nil)
        let byteSnapshot = await byBytes.service.cacheSnapshot()
        #expect(byteSnapshot.entryCount == 0)
        #expect(byteSnapshot.retainedByteCount == 0)
    }

    private struct Sandbox {
        let root: URL
        let projects: URL
        let working: URL
        let transcriptDirectory: URL
        let service: SupermuxHarnessSubagentTranscriptService

        var address: SupermuxHarnessSubagentTranscriptAddress { address(taskID: "task") }
        var transcriptURL: URL { transcriptURL(taskID: "task") }
        var metadataURL: URL {
            URL(fileURLWithPath: transcriptURL.deletingPathExtension().path + ".meta.json")
        }

        func address(taskID: String) -> SupermuxHarnessSubagentTranscriptAddress {
            .localAgent(workingDirectoryURL: working, sessionID: "session", taskID: taskID)
        }

        func transcriptURL(taskID: String) -> URL {
            transcriptDirectory.appendingPathComponent("agent-\(taskID).jsonl")
        }

        func createTranscriptDirectory() throws {
            try FileManager.default.createDirectory(
                at: transcriptDirectory,
                withIntermediateDirectories: true
            )
        }

        func write(_ lines: [String]) throws {
            try write(lines, to: transcriptURL)
        }

        func write(_ lines: [String], to url: URL) throws {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: url, atomically: false, encoding: .utf8)
        }

        func append(_ lines: [String]) throws {
            let handle = try FileHandle(forWritingTo: transcriptURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }

        func writeMetadata(_ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: metadataURL)
        }
    }

    private struct ChunkSnapshot {
        let processed: Int
        let drained: Int
    }

    /// One target has one scanner, so these hooks are serial; the suite reads only after awaiting it.
    private final class TranscriptMutationTracker: @unchecked Sendable {
        private let transcriptURL: URL
        private let replacementData: Data
        private var isArmed = false
        private var didMutate = false
        private(set) var scanStartCount = 0

        init(transcriptURL: URL, replacementData: Data) {
            self.transcriptURL = transcriptURL
            self.replacementData = replacementData
        }

        func recordScanStart() {
            scanStartCount += 1
        }

        func arm() {
            isArmed = true
        }

        func mutateWhenArmed() {
            guard isArmed, !didMutate else { return }
            didMutate = true
            let handle = try? FileHandle(forWritingTo: transcriptURL)
            try? handle?.truncate(atOffset: 0)
            try? handle?.write(contentsOf: replacementData)
            try? handle?.close()
        }
    }

    /// One target has one scanner, so these hooks are serial; the suite reads only after awaiting it.
    private final class MetadataMutationTracker: @unchecked Sendable {
        private let metadataURL: URL
        private var didMutate = false
        private(set) var scanStartCount = 0

        init(metadataURL: URL) {
            self.metadataURL = metadataURL
        }

        func recordScanStart() {
            scanStartCount += 1
        }

        func mutateOnce() {
            guard !didMutate else { return }
            didMutate = true
            let data = try? JSONSerialization.data(withJSONObject: ["description": "After"])
            try? data?.write(to: metadataURL)
        }
    }

    /// The service invokes chunk hooks serially; the serialized suite reads only after awaiting the scan.
    private final class ChunkTracker: @unchecked Sendable {
        private var processed = 0
        private var drained = 0

        func willProcessChunk() { processed += 1 }
        func didDrainChunk() { drained += 1 }
        func snapshot() -> ChunkSnapshot { ChunkSnapshot(processed: processed, drained: drained) }
    }

    private actor ScanGate {
        private var requests = 0
        private var starts = 0
        private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
        private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var firstReleased = false

        func requestDidBegin() {
            requests += 1
            let ready = requestCountWaiters.filter { requests >= $0.0 }
            requestCountWaiters.removeAll { requests >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }

        func waitUntilRequestCount(_ expected: Int) async {
            if requests >= expected { return }
            await withCheckedContinuation { continuation in
                requestCountWaiters.append((expected, continuation))
            }
        }

        func scanWillStart() async {
            starts += 1
            guard starts == 1 else { return }
            let waiters = firstStartedWaiters
            firstStartedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if firstReleased { return }
            await withCheckedContinuation { continuation in
                firstReleaseWaiters.append(continuation)
            }
        }

        func waitUntilFirstScanIsBlocked() async {
            if starts > 0 { return }
            await withCheckedContinuation { continuation in
                firstStartedWaiters.append(continuation)
            }
        }

        func releaseFirstScan() {
            firstReleased = true
            let waiters = firstReleaseWaiters
            firstReleaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func startedScanCount() -> Int { starts }
    }

    private actor ReadinessGate {
        private let expected: Int
        private var count = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(expected: Int) {
            self.expected = expected
        }

        func markReady() {
            count += 1
            guard count >= expected else { return }
            let current = waiters
            waiters.removeAll()
            for waiter in current { waiter.resume() }
        }

        func waitUntilReady() async {
            if count >= expected { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private func makeSandbox(
        named name: String,
        maximumTranscriptBytes: Int = 1 << 20,
        maximumCachedEntries: Int = 64,
        maximumCachedBytes: Int = 32 << 20,
        instrumentation: SupermuxHarnessSubagentTranscriptService.ScanInstrumentation? = nil
    ) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-transcript-behavior-\(name)-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let working = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        let projectName = try #require(discovery.mungedProjectDirectoryNames(for: working).first)
        let transcriptDirectory = projects
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        return Sandbox(
            root: root,
            projects: projects,
            working: working,
            transcriptDirectory: transcriptDirectory,
            service: SupermuxHarnessSubagentTranscriptService(
                projectsRootURL: projects,
                fileManager: .default,
                maximumTranscriptBytes: maximumTranscriptBytes,
                maximumCachedEntries: maximumCachedEntries,
                maximumCachedBytes: maximumCachedBytes,
                scanInstrumentation: instrumentation
            )
        )
    }

    private func assistantLine(uuid: String, text: String) -> String {
        "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"message\":{\"role\":\"assistant\",\"content\":\"\(text)\"}}"
    }

    private func eventIDs(_ update: SupermuxHarnessSubagentTranscriptUpdate) -> [String] {
        update.events.compactMap { $0.string(forKey: "uuid") }
    }
}

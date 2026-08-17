import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessSessionDiscoveryTests {
    private struct Sandbox {
        let root: URL
        let projects: URL
        let workingDirectory: URL
        let discovery: SupermuxHarnessSessionDiscovery
    }

    @Test func mungingResolvesSymlinkFirstAndProbesUnresolvedVariantSecond() throws {
        let root = try makeTemporaryDirectory(named: "munging")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target dir", isDirectory: true)
        let symlink = root.appendingPathComponent("linked-dir", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )

        let names = discovery.mungedProjectDirectoryNames(for: symlink)
        #expect(names == [munged(target.path), munged(symlink.path)])
        #expect(discovery.projectDirectoryURLs(for: symlink) == names.map {
            projects.appendingPathComponent($0, isDirectory: true)
        })
    }

    @Test func identicalResolvedAndUnresolvedPathsProduceOneCandidate() throws {
        let sandbox = try makeSandbox(named: "single-candidate")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(sandbox.discovery.mungedProjectDirectoryNames(for: sandbox.workingDirectory).count == 1)
        #expect(sandbox.discovery.projectDirectoryURLs(for: sandbox.workingDirectory).count == 1)
    }

    @Test func tmpResolutionUsesPrivateTmpCandidateFirstAcrossFoundationVersions() {
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: URL(fileURLWithPath: "/unused"),
            fileManager: .default
        )
        let names = discovery.mungedProjectDirectoryNames(for: URL(fileURLWithPath: "/tmp"))
        #expect(names.first == munged("/private/tmp"))
        #expect(names.contains(munged("/tmp")))
    }

    @Test func listSessionsAppliesTitlePrecedenceAndExtractsMetadata() throws {
        let sandbox = try makeSandbox(named: "metadata")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        try writeSession(id: "custom", directory: directory, records: [
            ["type": "user", "uuid": "u1", "isSidechain": false, "gitBranch": "main", "message": ["role": "user", "content": "First prompt"]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "u1", "isSidechain": false, "gitBranch": "feature", "message": ["role": "assistant", "content": "answer"]],
            ["type": "user", "uuid": "meta", "isMeta": true, "isSidechain": false, "message": ["role": "user", "content": "hidden"]],
            ["type": "assistant", "uuid": "side", "isSidechain": true, "message": ["role": "assistant", "content": "side"]],
            ["type": "summary", "summary": "Summary title"],
            ["type": "ai-title", "aiTitle": "AI title"],
            ["type": "custom-title", "customTitle": "Custom title"],
            ["type": "malformed but valid record"],
        ], modificationDate: baseDate)
        try writeSession(id: "ai", directory: directory, records: [
            ["type": "user", "uuid": "u", "message": ["role": "user", "content": "Prompt"]],
            ["type": "summary", "summary": "Summary"],
            ["type": "ai-title", "aiTitle": "AI title only"],
        ], modificationDate: baseDate.addingTimeInterval(1))
        try writeSession(id: "summary", directory: directory, records: [
            ["type": "user", "uuid": "u", "message": ["role": "user", "content": "Prompt"]],
            ["type": "summary", "summary": "Summary only"],
        ], modificationDate: baseDate.addingTimeInterval(2))
        try writeSession(id: "prompt", directory: directory, records: [
            ["type": "user", "uuid": "u", "message": ["role": "user", "content": [
                ["type": "text", "text": "First block"],
                ["type": "image", "source": ["type": "base64", "data": "AA=="]],
                ["type": "text", "text": "Second block"],
            ]]],
        ], modificationDate: baseDate.addingTimeInterval(3))
        let fallback = directory.appendingPathComponent("fallback.jsonl")
        try "not json\n{\"type\":\"queue-operation\"}\n".write(to: fallback, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: baseDate.addingTimeInterval(4)], ofItemAtPath: fallback.path)
        try "ignored".write(
            to: directory.appendingPathComponent("not-a-session.txt"),
            atomically: true,
            encoding: .utf8
        )

        let sessions = try sandbox.discovery.listSessions(for: sandbox.workingDirectory)
        #expect(sessions.map(\.sessionID) == ["fallback", "prompt", "summary", "ai", "custom"])
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        #expect(byID["custom"]?.title == "Custom title")
        #expect(byID["custom"]?.firstPrompt == "First prompt")
        #expect(byID["custom"]?.gitBranch == "feature")
        #expect(byID["custom"]?.messageCount == 2)
        #expect(byID["custom"]?.updatedAt == baseDate)
        #expect(byID["ai"]?.title == "AI title only")
        #expect(byID["summary"]?.title == "Summary only")
        #expect(byID["prompt"]?.title == "First block\nSecond block")
        #expect(byID["prompt"]?.firstPrompt == "First block\nSecond block")
        #expect(byID["fallback"]?.title == "fallback")
        #expect(byID["fallback"]?.messageCount == 0)
    }

    @Test func listSessionsSortsNewestFirstBreaksTiesByIDAndHonorsLimits() throws {
        let sandbox = try makeSandbox(named: "limits")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSession(id: "b", directory: directory, records: [], modificationDate: date)
        try writeSession(id: "a", directory: directory, records: [], modificationDate: date)
        try writeSession(id: "newest", directory: directory, records: [], modificationDate: date.addingTimeInterval(1))

        #expect(try sandbox.discovery.listSessions(for: sandbox.workingDirectory).map(\.sessionID) == ["newest", "a", "b"])
        #expect(try sandbox.discovery.listSessions(for: sandbox.workingDirectory, limit: 2).map(\.sessionID) == ["newest", "a"])
        #expect(try sandbox.discovery.listSessions(for: sandbox.workingDirectory, limit: 0).isEmpty)
        #expect(try sandbox.discovery.listSessions(for: sandbox.workingDirectory, limit: -1).isEmpty)
    }

    @Test func discoverySkipsOverlongRecordsAndContinuesAtTheNextLine() throws {
        let sandbox = try makeSandbox(named: "overlong-record")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        let oversizedContent = String(
            repeating: "x",
            count: SupermuxLineReader.maximumLineBytes + 1
        )
        try writeSession(id: "bounded", directory: directory, records: [
            [
                "type": "user",
                "uuid": "oversized",
                "cwd": sandbox.workingDirectory.path,
                "message": ["role": "user", "content": oversizedContent],
            ],
            [
                "type": "user",
                "uuid": "kept",
                "cwd": sandbox.workingDirectory.path,
                "message": ["role": "user", "content": "kept"],
            ],
        ])

        let session = try #require(
            sandbox.discovery.listSessions(for: sandbox.workingDirectory).first
        )
        #expect(session.messageCount == 1)
        #expect(session.firstPrompt == "kept")
        let history = try sandbox.discovery.loadHistory(
            for: sandbox.workingDirectory,
            sessionID: "bounded"
        )
        #expect(history.events.compactMap { $0.string(forKey: "uuid") } == ["kept"])
    }

    @Test func duplicateSessionAcrossResolvedAndUnresolvedCandidatesUsesNewestFile() throws {
        let root = try makeTemporaryDirectory(named: "dedupe")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let discovery = SupermuxHarnessSessionDiscovery(projectsRootURL: projects, fileManager: .default)
        let candidates = discovery.projectDirectoryURLs(for: link)
        #expect(candidates.count == 2)
        try FileManager.default.createDirectory(at: candidates[0], withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidates[1], withIntermediateDirectories: true)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSession(id: "same", directory: candidates[0], records: [
            ["type": "custom-title", "customTitle": "Resolved old"],
        ], modificationDate: oldDate)
        try writeSession(id: "same", directory: candidates[1], records: [
            ["type": "custom-title", "customTitle": "Unresolved new"],
        ], modificationDate: oldDate.addingTimeInterval(10))

        let session = try #require(discovery.listSessions(for: link).first)
        #expect(session.title == "Unresolved new")
        #expect(session.updatedAt == oldDate.addingTimeInterval(10))
    }

    @Test func historyWalksParentChainRatherThanFileOrderAndMapsLiveShapes() throws {
        let sandbox = try makeSandbox(named: "history")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        try writeSession(id: "chain", directory: directory, records: [
            ["type": "assistant", "uuid": "a4", "parentUuid": "side-bridge", "isSidechain": false, "sessionId": "stored-session", "timestamp": "t4", "message": ["role": "assistant", "content": "four"]],
            ["type": "assistant", "uuid": "unrelated", "parentUuid": NSNull(), "isSidechain": false, "message": ["role": "assistant", "content": "not selected"]],
            ["type": "assistant", "uuid": "a2", "parentUuid": "u1", "isSidechain": false, "subagent_type": "Explore", "task_description": "inspect", "message": ["role": "assistant", "content": "two"]],
            ["type": "assistant", "uuid": "meta", "parentUuid": "a2", "isMeta": true, "isSidechain": false, "message": ["role": "assistant", "content": "hidden meta"]],
            ["type": "assistant", "uuid": "a3", "parentUuid": "meta", "isSidechain": false, "error": "rate_limit", "aborted": true, "supersedes": ["old"], "message": ["role": "assistant", "content": "three"]],
            ["type": "assistant", "uuid": "side-bridge", "parentUuid": "a3", "isSidechain": true, "message": ["role": "assistant", "content": "hidden sidechain"]],
            ["type": "user", "uuid": "u1", "parentUuid": NSNull(), "isSidechain": false, "session_id": "wire-session", "toolUseResult": ["stdout": "ok"], "message": ["role": "user", "content": "one"]],
            ["type": "summary", "summary": "summary", "leafUuid": "a2"],
            ["type": "last-prompt", "leafUuid": "a4"],
        ])

        let page = try sandbox.discovery.loadHistory(
            for: sandbox.workingDirectory,
            sessionID: "chain"
        )
        #expect(!page.truncated)
        #expect(page.events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a2", "a3", "a4"])
        let user = try #require(page.events.first)
        #expect(user.string(forKey: "type") == "user")
        #expect(user.string(forKey: "session_id") == "wire-session")
        #expect(user.rawValue["parent_tool_use_id"] is NSNull)
        #expect(user.object(forKey: "tool_use_result")?.string(forKey: "stdout") == "ok")
        #expect(user.rawValue["toolUseResult"] == nil)
        let second = page.events[1]
        #expect(second.string(forKey: "subagent_type") == "Explore")
        #expect(second.string(forKey: "task_description") == "inspect")
        let third = page.events[2]
        #expect(third.string(forKey: "error") == "rate_limit")
        #expect(third.bool(forKey: "aborted") == true)
        let fourth = page.events[3]
        #expect(fourth.string(forKey: "session_id") == "stored-session")
        #expect(fourth.string(forKey: "timestamp") == "t4")
    }

    @Test func historyWalksThroughAttachmentAndSystemRecordsInTheParentChain() throws {
        // Real sessions interleave hook attachments, system records, and
        // file-history snapshots into the uuid chain. Indexing only
        // user/assistant records severed the walk at the first such bridge and
        // resumed panes showed just the trailing assistant messages.
        let sandbox = try makeSandbox(named: "bridge-records")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        try writeSession(id: "bridged", directory: directory, records: [
            ["type": "user", "uuid": "u1", "parentUuid": NSNull(), "isSidechain": false, "message": ["role": "user", "content": "first prompt"]],
            ["type": "attachment", "uuid": "att1", "parentUuid": "u1", "attachment": ["type": "hook_success"]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "att1", "isSidechain": false, "message": ["role": "assistant", "content": "first answer"]],
            ["type": "system", "uuid": "sys1", "parentUuid": "a1", "subtype": "informational"],
            ["type": "user", "uuid": "u2", "parentUuid": "sys1", "isSidechain": false, "message": ["role": "user", "content": "second prompt"]],
            ["type": "file-history-snapshot", "uuid": "fh1", "parentUuid": "u2", "messageId": "u2"],
            ["type": "assistant", "uuid": "a2", "parentUuid": "fh1", "isSidechain": false, "message": ["role": "assistant", "content": "second answer"]],
            ["type": "attachment", "uuid": "att2", "parentUuid": "a2", "attachment": ["type": "hook_success"]],
            ["type": "last-prompt", "leafUuid": "att2"],
        ])

        let page = try sandbox.discovery.loadHistory(
            for: sandbox.workingDirectory,
            sessionID: "bridged"
        )
        #expect(page.events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a1", "u2", "a2"])
    }

    @Test func sessionTitleFollowsPrecedenceAndReturnsNilWhenUntitled() throws {
        let sandbox = try makeSandbox(named: "session-title")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        try writeSession(id: "titled", directory: directory, records: [
            ["type": "user", "uuid": "u1", "isSidechain": false, "message": ["role": "user", "content": "first prompt"]],
            ["type": "ai-title", "aiTitle": "Topic from the CLI"],
        ])
        try writeSession(id: "untitled", directory: directory, records: [
            ["type": "queue-operation", "operation": "enqueue"],
        ])

        #expect(sandbox.discovery.sessionTitle(
            for: sandbox.workingDirectory,
            sessionID: "titled"
        ) == "Topic from the CLI")
        #expect(sandbox.discovery.sessionTitle(
            for: sandbox.workingDirectory,
            sessionID: "untitled"
        ) == nil)
        #expect(sandbox.discovery.sessionTitle(
            for: sandbox.workingDirectory,
            sessionID: "missing"
        ) == nil)
    }

    @Test func fixtureHistorySurfacesPersistedUserRecordUUIDs() throws {
        let sandbox = try makeSandbox(named: "fixture-user-uuids")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        let fixture = try #require(Bundle.module.url(
            forResource: "session-history-uuids",
            withExtension: "jsonl"
        ))
        try FileManager.default.copyItem(
            at: fixture,
            to: directory.appendingPathComponent("fixture-session.jsonl")
        )

        let page = try sandbox.discovery.loadHistory(
            for: sandbox.workingDirectory,
            sessionID: "fixture-session"
        )
        let userUUIDs = page.events.compactMap { event in
            event.string(forKey: "type") == "user" ? event.string(forKey: "uuid") : nil
        }

        #expect(userUUIDs == ["user-message-uuid-one", "user-message-uuid-two"])
    }

    @Test func historyLeafPreferenceIsLastPromptThenSummaryThenLastMainRecord() throws {
        let sandbox = try makeSandbox(named: "leaf-preference")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        let messages: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "isSidechain": false, "message": ["role": "user", "content": "one"]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "u1", "isSidechain": false, "message": ["role": "assistant", "content": "answer"]],
            ["type": "user", "uuid": "u2", "isSidechain": false, "message": ["role": "user", "content": "unrelated"]],
        ]
        try writeSession(id: "last", directory: directory, records: messages + [
            ["type": "summary", "summary": "summary", "leafUuid": "u1"],
            ["type": "last-prompt", "leafUuid": "a1"],
        ])
        try writeSession(id: "summary", directory: directory, records: messages + [
            ["type": "summary", "summary": "summary", "leafUuid": "a1"],
        ])
        try writeSession(id: "fallback", directory: directory, records: messages)
        try writeSession(id: "stale-last", directory: directory, records: messages + [
            ["type": "summary", "summary": "summary", "leafUuid": "a1"],
            ["type": "last-prompt", "leafUuid": "missing"],
        ])

        #expect(try sandbox.discovery.loadHistory(for: sandbox.workingDirectory, sessionID: "last").events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a1"])
        #expect(try sandbox.discovery.loadHistory(for: sandbox.workingDirectory, sessionID: "summary").events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a1"])
        #expect(try sandbox.discovery.loadHistory(for: sandbox.workingDirectory, sessionID: "fallback").events.compactMap { $0.string(forKey: "uuid") } == ["u2"])
        #expect(try sandbox.discovery.loadHistory(for: sandbox.workingDirectory, sessionID: "stale-last").events.compactMap { $0.string(forKey: "uuid") } == ["u1", "a1"])
    }

    @Test func historyReturnsNewestBoundedEventsAndTruncationFlag() throws {
        let sandbox = try makeSandbox(named: "pagination")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        try writeSession(id: "page", directory: directory, records: [
            ["type": "user", "uuid": "1", "isSidechain": false, "message": ["role": "user", "content": "1"]],
            ["type": "assistant", "uuid": "2", "parentUuid": "1", "isSidechain": false, "message": ["role": "assistant", "content": "2"]],
            ["type": "user", "uuid": "3", "parentUuid": "2", "isSidechain": false, "message": ["role": "user", "content": "3"]],
            ["type": "last-prompt", "leafUuid": "3"],
        ])

        let two = try sandbox.discovery.loadHistory(for: sandbox.workingDirectory, sessionID: "page", recordLimit: 2)
        #expect(two.truncated)
        #expect(two.events.compactMap { $0.string(forKey: "uuid") } == ["2", "3"])
        let all = try sandbox.discovery.loadHistory(for: sandbox.workingDirectory, sessionID: "page", recordLimit: 3)
        #expect(!all.truncated)
        let zero = try sandbox.discovery.loadHistory(for: sandbox.workingDirectory, sessionID: "page", recordLimit: 0)
        #expect(zero.truncated)
        #expect(zero.events.isEmpty)
    }

    @Test func cwdMungingCollisionsDoNotExposeAnotherDirectorysSessions() throws {
        let root = try makeTemporaryDirectory(named: "cwd-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let requestedDirectory = root.appendingPathComponent("project-a", isDirectory: true)
        let collidingDirectory = root.appendingPathComponent("project_a", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: requestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: collidingDirectory, withIntermediateDirectories: true)
        let discovery = SupermuxHarnessSessionDiscovery(projectsRootURL: projects, fileManager: .default)
        #expect(
            discovery.mungedProjectDirectoryNames(for: requestedDirectory) ==
                discovery.mungedProjectDirectoryNames(for: collidingDirectory)
        )
        let projectDirectory = try #require(discovery.projectDirectoryURLs(for: requestedDirectory).first)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try writeSession(id: "foreign", directory: projectDirectory, records: [
            [
                "type": "user",
                "uuid": "user",
                "cwd": collidingDirectory.path,
                "isSidechain": false,
                "message": ["role": "user", "content": "private prompt"],
            ],
        ])

        #expect(try discovery.listSessions(for: requestedDirectory).isEmpty)
        #expect(throws: SupermuxHarnessSessionDiscoveryError.sessionNotFound("foreign")) {
            _ = try discovery.loadHistory(for: requestedDirectory, sessionID: "foreign")
        }
        #expect(try discovery.listSessions(for: collidingDirectory).map(\.sessionID) == ["foreign"])
        #expect(
            try discovery.loadHistory(for: collidingDirectory, sessionID: "foreign")
                .events.first?.string(forKey: "uuid") == "user"
        )
    }

    @Test func discoveryRejectsSymlinkedProjectDirectoriesAndSessionFiles() throws {
        let root = try makeTemporaryDirectory(named: "symlink-escape")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("working", isDirectory: true)
        let outsideProject = root.appendingPathComponent("outside-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideProject, withIntermediateDirectories: true)
        let discovery = SupermuxHarnessSessionDiscovery(projectsRootURL: projects, fileManager: .default)
        let projectDirectory = try #require(discovery.projectDirectoryURLs(for: workingDirectory).first)
        try writeSession(id: "escaped-project", directory: outsideProject, records: [
            [
                "type": "user",
                "uuid": "project-user",
                "cwd": workingDirectory.path,
                "message": ["role": "user", "content": "outside"],
            ],
        ])
        try FileManager.default.createSymbolicLink(at: projectDirectory, withDestinationURL: outsideProject)

        #expect(try discovery.listSessions(for: workingDirectory).isEmpty)
        #expect(throws: SupermuxHarnessSessionDiscoveryError.sessionNotFound("escaped-project")) {
            _ = try discovery.loadHistory(for: workingDirectory, sessionID: "escaped-project")
        }

        try FileManager.default.removeItem(at: projectDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let outsideFile = try writeSession(id: "outside-file", directory: outsideProject, records: [
            [
                "type": "user",
                "uuid": "file-user",
                "cwd": workingDirectory.path,
                "message": ["role": "user", "content": "outside file"],
            ],
        ])
        let linkedFile = projectDirectory.appendingPathComponent("escaped-file.jsonl")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: outsideFile)

        #expect(try discovery.listSessions(for: workingDirectory).isEmpty)
        #expect(throws: SupermuxHarnessSessionDiscoveryError.sessionNotFound("escaped-file")) {
            _ = try discovery.loadHistory(for: workingDirectory, sessionID: "escaped-file")
        }
    }

    @Test func sessionListSkipsFileNamesThatHistoryCannotAddress() throws {
        let sandbox = try makeSandbox(named: "invalid-list-id")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let directory = try firstProjectDirectory(in: sandbox)
        try writeSession(id: "bad id", directory: directory, records: [])
        try writeSession(id: "valid-id", directory: directory, records: [])

        #expect(try sandbox.discovery.listSessions(for: sandbox.workingDirectory).map(\.sessionID) == ["valid-id"])
    }

    @Test(arguments: ["", "../session", "folder/session", ".", "session.jsonl", "session id"])
    func historyRejectsInvalidSessionIdentifiers(_ sessionID: String) throws {
        let sandbox = try makeSandbox(named: "invalid-id")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(throws: SupermuxHarnessSessionDiscoveryError.invalidSessionID) {
            _ = try sandbox.discovery.loadHistory(
                for: sandbox.workingDirectory,
                sessionID: sessionID
            )
        }
    }

    @Test func historyReportsMissingValidSessionIdentifier() throws {
        let sandbox = try makeSandbox(named: "missing")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(throws: SupermuxHarnessSessionDiscoveryError.sessionNotFound("missing-session")) {
            _ = try sandbox.discovery.loadHistory(
                for: sandbox.workingDirectory,
                sessionID: "missing-session"
            )
        }
    }

    private func makeSandbox(named name: String) throws -> Sandbox {
        let root = try makeTemporaryDirectory(named: name)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return Sandbox(
            root: root,
            projects: projects,
            workingDirectory: workingDirectory,
            discovery: SupermuxHarnessSessionDiscovery(projectsRootURL: projects, fileManager: .default)
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func firstProjectDirectory(in sandbox: Sandbox) throws -> URL {
        let directory = try #require(
            sandbox.discovery.projectDirectoryURLs(for: sandbox.workingDirectory).first
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func writeSession(
        id: String,
        directory: URL,
        records: [[String: Any]],
        modificationDate: Date? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent(id).appendingPathExtension("jsonl")
        let lines = try records.map { record in
            String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: url, atomically: true, encoding: .utf8)
        if let modificationDate {
            try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        return url
    }

    private func munged(_ path: String) -> String {
        path.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }
}

import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessSubagentTranscriptReaderTests {
    @Test func localAgentUsesResolvedCwdMungingAndSharedHistoryMapping() throws {
        let sandbox = try makeSandbox(named: "local")
        let workingDirectory = URL(fileURLWithPath: "/tmp/supermux transcript \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workingDirectory)
            try? FileManager.default.removeItem(at: sandbox.root)
        }
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: sandbox.projects,
            fileManager: .default
        )
        let projectName = try #require(
            discovery.mungedProjectDirectoryNames(for: workingDirectory).first
        )
        let claudeResolvedPath = "/private\(workingDirectory.standardizedFileURL.path)"
        #expect(projectName == munged(claudeResolvedPath))

        let transcriptDirectory = sandbox.projects
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try writeJSONLines([
            [
                "type": "user",
                "uuid": "user-1",
                "sessionId": "stored-session",
                "cwd": workingDirectory.path,
                "message": ["role": "user", "content": "prompt"],
                "toolUseResult": ["stdout": "ok"],
            ],
            [
                "type": "assistant",
                "uuid": "assistant-1",
                "message": ["role": "assistant", "content": "answer"],
            ],
        ], to: transcriptDirectory.appendingPathComponent("agent-task-1.jsonl"))
        try writeJSONObject([
            "agentType": "general-purpose",
            "description": "Inspect the project",
            "spawnDepth": 2,
        ], to: transcriptDirectory.appendingPathComponent("agent-task-1.meta.json"))

        let page = try sandbox.reader.loadLocalAgentTranscript(
            for: workingDirectory,
            sessionID: "session-1",
            taskID: "task-1"
        )

        #expect(!page.missing)
        #expect(!page.truncated)
        #expect(page.events.compactMap { $0.string(forKey: "uuid") } == ["user-1", "assistant-1"])
        #expect(page.events[0].string(forKey: "session_id") == "stored-session")
        #expect(page.events[0].object(forKey: "tool_use_result")?.string(forKey: "stdout") == "ok")
        #expect(page.events[1].string(forKey: "session_id") == "session-1")
        #expect(page.metadata == SupermuxHarnessSubagentTranscriptMetadata(
            agentType: "general-purpose",
            description: "Inspect the project",
            spawnDepth: 2
        ))
    }

    @Test func workflowAgentUsesWorkflowRunSubdirectory() throws {
        let sandbox = try makeSandbox(named: "workflow")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let workingDirectory = sandbox.root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let projectName = try projectName(for: workingDirectory, projects: sandbox.projects)
        let runDirectory = sandbox.projects
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try writeJSONLines([
            [
                "type": "assistant",
                "uuid": "workflow-answer",
                "message": ["role": "assistant", "content": "alpha"],
            ],
        ], to: runDirectory.appendingPathComponent("agent-agent-1.jsonl"))
        try writeJSONObject([
            "agentType": "workflow-subagent",
            "spawnDepth": 1,
        ], to: runDirectory.appendingPathComponent("agent-agent-1.meta.json"))

        let page = try sandbox.reader.loadWorkflowAgentTranscript(
            for: workingDirectory,
            sessionID: "session",
            workflowRunID: "wf_run-1",
            agentID: "agent-1"
        )

        #expect(page.events.first?.string(forKey: "uuid") == "workflow-answer")
        #expect(page.metadata?.agentType == "workflow-subagent")
        #expect(page.metadata?.spawnDepth == 1)
    }

    @Test func missingTranscriptReturnsCalmMissingPage() throws {
        let sandbox = try makeSandbox(named: "missing")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let workingDirectory = sandbox.root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let page = try sandbox.reader.loadLocalAgentTranscript(
            for: workingDirectory,
            sessionID: "session",
            taskID: "task"
        )

        #expect(page.missing)
        #expect(page.events.isEmpty)
        #expect(!page.truncated)
        #expect(page.metadata == nil)
    }

    @Test func transcriptRetainsNewestEventsWithinByteLimitAndReportsTruncation() throws {
        let sandbox = try makeSandbox(named: "truncated", maximumTranscriptBytes: 220)
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let workingDirectory = sandbox.root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let projectName = try projectName(for: workingDirectory, projects: sandbox.projects)
        let transcriptDirectory = sandbox.projects
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try writeJSONLines((1...5).map { index in
            [
                "type": "assistant",
                "uuid": "event-\(index)",
                "message": ["role": "assistant", "content": String(repeating: "x", count: 40)],
            ]
        }, to: transcriptDirectory.appendingPathComponent("agent-task.jsonl"))

        let page = try sandbox.reader.loadLocalAgentTranscript(
            for: workingDirectory,
            sessionID: "session",
            taskID: "task"
        )

        #expect(page.truncated)
        #expect(!page.events.isEmpty)
        #expect(page.events.last?.string(forKey: "uuid") == "event-5")
        #expect(page.events.first?.string(forKey: "uuid") != "event-1")
    }

    @Test func cwdMungingCollisionCannotExposeAnotherDirectorysTranscript() throws {
        let sandbox = try makeSandbox(named: "cwd-collision")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let requestedDirectory = sandbox.root.appendingPathComponent("project-a", isDirectory: true)
        let collidingDirectory = sandbox.root.appendingPathComponent("project_a", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: collidingDirectory, withIntermediateDirectories: true)
        let requestedProjectName = try projectName(
            for: requestedDirectory,
            projects: sandbox.projects
        )
        let collidingProjectName = try projectName(
            for: collidingDirectory,
            projects: sandbox.projects
        )
        #expect(requestedProjectName == collidingProjectName)
        let transcriptDirectory = sandbox.projects
            .appendingPathComponent(requestedProjectName, isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try writeJSONLines([
            [
                "type": "assistant",
                "uuid": "foreign",
                "cwd": collidingDirectory.path,
                "message": ["role": "assistant", "content": "private"],
            ],
        ], to: transcriptDirectory.appendingPathComponent("agent-task.jsonl"))

        #expect(throws: SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath) {
            _ = try sandbox.reader.loadLocalAgentTranscript(
                for: requestedDirectory,
                sessionID: "session",
                taskID: "task"
            )
        }
    }

    @Test(arguments: ["../task", "workflow/run", "agent.jsonl", ""])
    func unsafeIdentifiersAreRejected(_ identifier: String) throws {
        let sandbox = try makeSandbox(named: "unsafe-id")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(throws: SupermuxHarnessSubagentTranscriptReaderError.invalidIdentifier) {
            _ = try sandbox.reader.loadLocalAgentTranscript(
                for: sandbox.root,
                sessionID: "session",
                taskID: identifier
            )
        }
    }

    private struct Sandbox {
        let root: URL
        let projects: URL
        let reader: SupermuxHarnessSubagentTranscriptReader
    }

    private func makeSandbox(
        named name: String,
        maximumTranscriptBytes: Int = 1 << 20
    ) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-subagent-\(name)-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return Sandbox(
            root: root,
            projects: projects,
            reader: SupermuxHarnessSubagentTranscriptReader(
                projectsRootURL: projects,
                fileManager: .default,
                maximumTranscriptBytes: maximumTranscriptBytes
            )
        )
    }

    private func projectName(for workingDirectory: URL, projects: URL) throws -> String {
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        return try #require(discovery.mungedProjectDirectoryNames(for: workingDirectory).first)
    }

    private func writeJSONLines(_ records: [[String: Any]], to url: URL) throws {
        let lines = try records.map { record in
            String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }

    private func munged(_ path: String) -> String {
        path.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }
}

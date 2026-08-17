import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessTaskOutputReaderTests {
    @Test func knownTaskReadsApproximatelyLast64KiB() throws {
        let sandbox = try makeSandbox(named: "tail")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let outputURL = try makeOutputFile(
            in: sandbox.root,
            taskID: "task-1",
            data: Data(repeating: UInt8(ascii: "a"), count: (64 << 10) + 100)
                + Data("tail".utf8)
        )

        let page = try sandbox.reader.read(
            taskID: "task-1",
            observedTaskIDs: ["task-1"],
            outputFilePath: outputURL.path
        )

        #expect(!page.missing)
        #expect(page.truncated)
        #expect(page.text.utf8.count == 64 << 10)
        #expect(page.text.hasSuffix("tail"))
    }

    @Test func tmpAliasRootAcceptsPrivateTmpProtocolPath() throws {
        let container = URL(
            fileURLWithPath: "/tmp/supermux-task-output-alias-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = container.appendingPathComponent("claude-501", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let outputURL = try makeOutputFile(
            in: root,
            taskID: "task",
            data: Data("physical path".utf8)
        )
        let canonicalRoot = URL(
            fileURLWithPath: root.path.hasPrefix("/private/tmp/")
                ? root.path
                : "/private\(root.path)",
            isDirectory: true
        )
        let reader = SupermuxHarnessTaskOutputReader(
            temporaryRootURL: root,
            canonicalRootURL: canonicalRoot,
            fileManager: .default
        )
        let privatePath = outputURL.path.hasPrefix("/private/tmp/")
            ? outputURL.path
            : "/private\(outputURL.path)"

        let page = try reader.read(
            taskID: "task",
            observedTaskIDs: ["task"],
            outputFilePath: privatePath
        )

        #expect(page.text == "physical path")
        #expect(!page.missing)
    }

    @Test func unknownTaskIdentifierIsRejectedBeforeAnyPathRead() throws {
        let sandbox = try makeSandbox(named: "unknown")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        #expect(throws: SupermuxHarnessTaskOutputReaderError.unknownTaskID) {
            _ = try sandbox.reader.read(
                taskID: "unknown",
                observedTaskIDs: ["known"],
                outputFilePath: sandbox.root
                    .appendingPathComponent("tasks/unknown.output")
                    .path
            )
        }
    }

    @Test func unsafeTaskIdentifierAndTraversalPathAreRejected() throws {
        let sandbox = try makeSandbox(named: "traversal")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        #expect(throws: SupermuxHarnessTaskOutputReaderError.invalidTaskID) {
            _ = try sandbox.reader.read(
                taskID: "../task",
                observedTaskIDs: ["../task"],
                outputFilePath: sandbox.root.path + "/session/tasks/../task.output"
            )
        }
        #expect(throws: SupermuxHarnessTaskOutputReaderError.unsafeOutputPath) {
            _ = try sandbox.reader.read(
                taskID: "task",
                observedTaskIDs: ["task"],
                outputFilePath: sandbox.root.path + "/session/tasks/../tasks/task.output"
            )
        }
    }

    @Test func outOfRootSymlinkIsRejectedAfterCanonicalization() throws {
        let sandbox = try makeSandbox(named: "symlink")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let tasks = sandbox.root
            .appendingPathComponent("munged", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let outside = sandbox.container.appendingPathComponent("outside.output")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        let linkedOutput = tasks.appendingPathComponent("task.output")
        try FileManager.default.createSymbolicLink(at: linkedOutput, withDestinationURL: outside)

        #expect(throws: SupermuxHarnessTaskOutputReaderError.unsafeOutputPath) {
            _ = try sandbox.reader.read(
                taskID: "task",
                observedTaskIDs: ["task"],
                outputFilePath: linkedOutput.path
            )
        }
    }

    @Test func symlinkedClaudeRootCannotRedefineCanonicalBoundary() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-task-root-symlink-\(UUID().uuidString)", isDirectory: true)
        let expectedRoot = container.appendingPathComponent("claude-501", isDirectory: true)
        let outsideRoot = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: expectedRoot, withDestinationURL: outsideRoot)
        defer { try? FileManager.default.removeItem(at: container) }
        let outputURL = try makeOutputFile(
            in: expectedRoot,
            taskID: "task",
            data: Data("escaped".utf8)
        )
        let reader = SupermuxHarnessTaskOutputReader(
            temporaryRootURL: expectedRoot,
            canonicalRootURL: expectedRoot,
            fileManager: .default
        )

        #expect(throws: SupermuxHarnessTaskOutputReaderError.unsafeOutputPath) {
            _ = try reader.read(
                taskID: "task",
                observedTaskIDs: ["task"],
                outputFilePath: outputURL.path
            )
        }
    }

    @Test func missingValidatedOutputIsNotAnExceptionalFailure() throws {
        let sandbox = try makeSandbox(named: "missing")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let missing = sandbox.root
            .appendingPathComponent("munged", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("task.output")

        let page = try sandbox.reader.read(
            taskID: "task",
            observedTaskIDs: ["task"],
            outputFilePath: missing.path
        )

        #expect(page.missing)
        #expect(page.text.isEmpty)
        #expect(!page.truncated)
    }

    @Test func independentlyDerivedSessionPathMustMatchProtocolPath() throws {
        let sandbox = try makeSandbox(named: "session-match")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let first = try makeOutputFile(
            in: sandbox.root.appendingPathComponent("first", isDirectory: true),
            taskID: "task",
            data: Data("first".utf8)
        )
        let second = try makeOutputFile(
            in: sandbox.root.appendingPathComponent("second", isDirectory: true),
            taskID: "task",
            data: Data("second".utf8)
        )

        #expect(throws: SupermuxHarnessTaskOutputReaderError.unsafeOutputPath) {
            _ = try sandbox.reader.read(
                taskID: "task",
                observedTaskIDs: ["task"],
                outputFilePath: first.path,
                expectedOutputFilePath: second.path
            )
        }
    }

    @Test func exactTaskSuffixIsRequired() throws {
        let sandbox = try makeSandbox(named: "suffix")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        #expect(throws: SupermuxHarnessTaskOutputReaderError.unsafeOutputPath) {
            _ = try sandbox.reader.read(
                taskID: "task",
                observedTaskIDs: ["task"],
                outputFilePath: sandbox.root.path + "/munged/session/tasks/other.output"
            )
        }
    }

    private struct Sandbox {
        let container: URL
        let root: URL
        let reader: SupermuxHarnessTaskOutputReader
    }

    private func makeSandbox(named name: String) throws -> Sandbox {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-task-output-\(name)-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("claude-501", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Sandbox(
            container: container,
            root: root,
            reader: SupermuxHarnessTaskOutputReader(
                temporaryRootURL: root,
                canonicalRootURL: root.resolvingSymlinksInPath(),
                fileManager: .default
            )
        )
    }

    private func makeOutputFile(
        in root: URL,
        taskID: String,
        data: Data
    ) throws -> URL {
        let tasks = root
            .appendingPathComponent("munged", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let output = tasks.appendingPathComponent("\(taskID).output")
        try data.write(to: output)
        return output
    }
}

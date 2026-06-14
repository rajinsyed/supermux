import Foundation
import Testing
@testable import SupermuxKit

/// Behavior tests for feature 2 (AI "Generate & Commit") at the
/// ``SupermuxChangesModel`` layer, against a real temporary git repository.
///
/// Serialized because it shells out to real `git`.
@MainActor
@Suite(.serialized)
struct SupermuxAICommitFlowTests {
    /// AI generator that returns a fixed message and reports configured.
    private struct FixedCommitGenerator: SupermuxAICommitMessaging {
        let message: String
        let configured: Bool
        func isConfigured() async -> Bool { configured }
        func generateMessage(forDiff diff: String) async -> String? { configured ? message : nil }
    }

    /// Generator that reports configured but fails to produce a message — models
    /// a reachable-but-failing gateway (network error / non-2xx / empty reply).
    private struct FailingCommitGenerator: SupermuxAICommitMessaging {
        func isConfigured() async -> Bool { true }
        func generateMessage(forDiff diff: String) async -> String? { nil }
    }

    @Test func emptyMessageStagesAllAndCommitsGeneratedMessage() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try write("hello\n", to: "README.md", in: repo)        // modify tracked
        try write("new\n", to: "feature.txt", in: repo)        // add untracked

        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: FixedCommitGenerator(message: "feat: add greeting", configured: true)
        )
        model.setDirectory(repo)
        await pollUntil { model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 }

        #expect(model.aiCommitConfigured)
        #expect(model.isAICommitMode)            // empty message + configured + changes
        #expect(model.canCommit)

        await model.performCommit()
        await pollUntil { !model.isWorking && model.snapshot.totalChangeCount == 0 }

        #expect(try lastCommitSubject(in: repo) == "feat: add greeting")
        #expect(model.commitMessage.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test func typedMessageCommitsDirectlyWithoutAI() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try write("hello\n", to: "README.md", in: repo)

        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: FixedCommitGenerator(message: "feat: SHOULD-NOT-BE-USED", configured: true)
        )
        model.setDirectory(repo)
        await pollUntil { model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 }
        await model.stageAll()
        await pollUntil { !model.isWorking && !model.snapshot.staged.isEmpty }

        model.commitMessage = "fix: manual message"
        #expect(!model.isAICommitMode)           // typed message wins
        await model.performCommit()
        await pollUntil { !model.isWorking && model.snapshot.totalChangeCount == 0 }

        #expect(try lastCommitSubject(in: repo) == "fix: manual message")
    }

    @Test func notConfiguredDisablesAICommitAndDoesNotStage() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try write("hello\n", to: "README.md", in: repo)

        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: FixedCommitGenerator(message: "feat: x", configured: false)
        )
        model.setDirectory(repo)
        await pollUntil { model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 }

        #expect(!model.aiCommitConfigured)
        #expect(!model.isAICommitMode)
        #expect(!model.canCommit)                // empty message + not configured

        await model.performCommit()              // no-op guard / early bail
        await pollUntil { !model.isWorking }

        #expect(try lastCommitSubject(in: repo) == "Initial commit")  // nothing committed
        #expect(model.snapshot.staged.isEmpty)                        // nothing staged
    }

    @Test func generationFailureLeavesTreeUnstagedAndUncommitted() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try write("hello\n", to: "README.md", in: repo)
        try write("new\n", to: "feature.txt", in: repo)

        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: FailingCommitGenerator()
        )
        model.setDirectory(repo)
        await pollUntil { model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 }

        await model.performCommit()
        await pollUntil { !model.isWorking }

        // Atomic: a failed message must not stage the tree or create a commit.
        #expect(model.snapshot.staged.isEmpty)
        #expect(try lastCommitSubject(in: repo) == "Initial commit")
        #expect(model.lastError != nil)
    }

    // MARK: - Fixture helpers

    private func pollUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeFixtureRepo() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-ai-commit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = (url.path as NSString).standardizingPath
        try runGit(["init", "-b", "main"], in: root)
        try runGit(["config", "--local", "user.email", "tests@supermux.invalid"], in: root)
        try runGit(["config", "--local", "user.name", "Supermux Tests"], in: root)
        try runGit(["config", "--local", "commit.gpgsign", "false"], in: root)
        try write("fixture\n", to: "README.md", in: root)
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-m", "Initial commit"], in: root)
        return root
    }

    private func write(_ content: String, to relativePath: String, in root: String) throws {
        try content.write(
            toFile: (root as NSString).appendingPathComponent(relativePath),
            atomically: true,
            encoding: .utf8
        )
    }

    private func lastCommitSubject(in root: String) throws -> String {
        try runGit(["log", "-1", "--pretty=%s"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

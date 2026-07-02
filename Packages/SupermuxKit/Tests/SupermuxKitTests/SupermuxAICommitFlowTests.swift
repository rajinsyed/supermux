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

    /// Generator that mutates the repository during its first (multi-second in
    /// production) generation call — modeling files changing while the AI
    /// request is in flight — and returns a distinct message per call.
    private actor RepoMutatingGenerator: SupermuxAICommitMessaging {
        private let repo: String
        private(set) var callCount = 0

        init(repo: String) { self.repo = repo }

        func isConfigured() async -> Bool { true }

        func generateMessage(forDiff diff: String) async -> String? {
            callCount += 1
            if callCount == 1 {
                // A file appears while the "AI" is thinking.
                try? "sneaky\n".write(
                    toFile: (repo as NSString).appendingPathComponent("sneaky.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                return "feat: stale message"
            }
            return "feat: fresh message"
        }
    }

    @Test func emptyMessageStagesAllAndCommitsGeneratedMessage() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try GitFixture.write("hello\n", to: "README.md", in: repo)        // modify tracked
        try GitFixture.write("new\n", to: "feature.txt", in: repo)        // add untracked

        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: FixedCommitGenerator(message: "feat: add greeting", configured: true)
        )
        model.setDirectory(repo)
        // aiCommitConfigured is probed at the end of the same refresh that fills
        // the snapshot, so poll for it too — otherwise this races under full-suite
        // load (the snapshot can be ready a beat before the AI probe resolves).
        await pollUntil {
            model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 && model.aiCommitConfigured
        }

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
        try GitFixture.write("hello\n", to: "README.md", in: repo)

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
        try GitFixture.write("hello\n", to: "README.md", in: repo)

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
        try GitFixture.write("hello\n", to: "README.md", in: repo)
        try GitFixture.write("new\n", to: "feature.txt", in: repo)

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

    /// Staleness guard: files changing during the AI call must not be swept
    /// into the commit under the stale message — the flow re-captures the
    /// diff after generation and regenerates ONCE from the fresh one.
    @Test func changesDuringGenerationRegenerateMessageOnce() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try GitFixture.write("hello\n", to: "README.md", in: repo)

        let generator = RepoMutatingGenerator(repo: repo)
        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: generator
        )
        model.setDirectory(repo)
        await pollUntil {
            model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 && model.aiCommitConfigured
        }

        await model.performCommit()
        await pollUntil { !model.isWorking && model.snapshot.totalChangeCount == 0 }

        // Regenerated exactly once (2 calls, never a loop), committed the
        // fresh message, and the mid-flight file is part of the commit.
        #expect(await generator.callCount == 2)
        #expect(try lastCommitSubject(in: repo) == "feat: fresh message")
        let committedFiles = try GitFixture.runGit(
            ["show", "--name-only", "--format=", "HEAD"], in: repo
        )
        #expect(committedFiles.contains("sneaky.txt"))
        #expect(model.lastError == nil)
    }

    /// Generator that rewrites an already-modified tracked file's *content*
    /// during its first generation call — no path or kind changes, so a
    /// status-level fingerprint (kinds+paths) cannot see it; only the diff
    /// content differs.
    private actor ContentMutatingGenerator: SupermuxAICommitMessaging {
        private let repo: String
        private(set) var callCount = 0

        init(repo: String) { self.repo = repo }

        func isConfigured() async -> Bool { true }

        func generateMessage(forDiff diff: String) async -> String? {
            callCount += 1
            if callCount == 1 {
                try? "hello edited mid-flight\n".write(
                    toFile: (repo as NSString).appendingPathComponent("README.md"),
                    atomically: true,
                    encoding: .utf8
                )
                return "feat: stale message"
            }
            return "feat: fresh message"
        }
    }

    /// Content-only staleness: editing an already-modified file during the AI
    /// call changes no path or kind, yet its newer content is what `git add -A`
    /// sweeps into the commit — the guard must compare diff content and
    /// regenerate.
    @Test func contentOnlyEditDuringGenerationRegeneratesMessage() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try GitFixture.write("hello\n", to: "README.md", in: repo)

        let generator = ContentMutatingGenerator(repo: repo)
        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: generator
        )
        model.setDirectory(repo)
        await pollUntil {
            model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 && model.aiCommitConfigured
        }

        await model.performCommit()
        await pollUntil { !model.isWorking && model.snapshot.totalChangeCount == 0 }

        #expect(await generator.callCount == 2)
        #expect(try lastCommitSubject(in: repo) == "feat: fresh message")
        #expect(try GitFixture.runGit(["show", "HEAD:README.md"], in: repo) == "hello edited mid-flight\n")
        #expect(model.lastError == nil)
    }

    /// Generator that rewrites an *untracked* file's content during its first
    /// generation call. The AI diff carries untracked files by name only, so
    /// only the untracked-content identity can catch this.
    private actor UntrackedMutatingGenerator: SupermuxAICommitMessaging {
        private let repo: String
        private(set) var callCount = 0

        init(repo: String) { self.repo = repo }

        func isConfigured() async -> Bool { true }

        func generateMessage(forDiff diff: String) async -> String? {
            callCount += 1
            if callCount == 1 {
                try? "v2 rewritten mid-flight\n".write(
                    toFile: (repo as NSString).appendingPathComponent("notes.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                return "feat: stale message"
            }
            return "feat: fresh message"
        }
    }

    /// Untracked-content staleness: rewriting an untracked file during the AI
    /// call changes no name in the diff, yet `git add -A` commits the newer
    /// bytes — the guard's untracked identity must catch it and regenerate.
    @Test func untrackedContentEditDuringGenerationRegeneratesMessage() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try GitFixture.write("v1\n", to: "notes.txt", in: repo)   // untracked

        let generator = UntrackedMutatingGenerator(repo: repo)
        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: generator
        )
        model.setDirectory(repo)
        await pollUntil {
            model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 && model.aiCommitConfigured
        }

        await model.performCommit()
        await pollUntil { !model.isWorking && model.snapshot.totalChangeCount == 0 }

        #expect(await generator.callCount == 2)
        #expect(try lastCommitSubject(in: repo) == "feat: fresh message")
        #expect(try GitFixture.runGit(["show", "HEAD:notes.txt"], in: repo) == "v2 rewritten mid-flight\n")
        #expect(model.lastError == nil)
    }

    /// Generator that rewrites the tracked file on *every* call, so the tree
    /// never stabilizes across the single regeneration.
    private actor RestlessGenerator: SupermuxAICommitMessaging {
        private let repo: String
        private(set) var callCount = 0

        init(repo: String) { self.repo = repo }

        func isConfigured() async -> Bool { true }

        func generateMessage(forDiff diff: String) async -> String? {
            callCount += 1
            try? "restless edit #\(callCount)\n".write(
                toFile: (repo as NSString).appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
            return "feat: message \(callCount)"
        }
    }

    /// A tree that shifts again after the single regeneration aborts without
    /// staging or committing (never commits blind, never loops).
    @Test func treeShiftingAfterRegenerationAbortsWithoutCommitting() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try GitFixture.write("hello\n", to: "README.md", in: repo)

        let generator = RestlessGenerator(repo: repo)
        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: generator
        )
        model.setDirectory(repo)
        await pollUntil {
            model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 && model.aiCommitConfigured
        }

        await model.performCommit()
        await pollUntil { !model.isWorking }

        #expect(await generator.callCount == 2)      // regenerated once, never a loop
        #expect(try lastCommitSubject(in: repo) == "Initial commit")
        #expect(model.snapshot.staged.isEmpty)
        #expect(model.lastError != nil)
    }

    /// A stable change set generates exactly once — the guard must not cost a
    /// second gateway round-trip when nothing changed.
    @Test func stableChangeSetGeneratesOnlyOnce() async throws {
        let repo = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try GitFixture.write("hello\n", to: "README.md", in: repo)

        let generator = CountingCommitGenerator(message: "feat: single shot")
        let model = SupermuxChangesModel(
            service: SupermuxGitChangesService(),
            commitGenerator: generator
        )
        model.setDirectory(repo)
        await pollUntil {
            model.snapshot.isRepository && model.snapshot.totalChangeCount > 0 && model.aiCommitConfigured
        }

        await model.performCommit()
        await pollUntil { !model.isWorking && model.snapshot.totalChangeCount == 0 }

        #expect(await generator.callCount == 1)
        #expect(try lastCommitSubject(in: repo) == "feat: single shot")
    }

    /// Configured generator that counts its calls and returns a fixed message.
    private actor CountingCommitGenerator: SupermuxAICommitMessaging {
        private let message: String
        private(set) var callCount = 0

        init(message: String) { self.message = message }

        func isConfigured() async -> Bool { true }
        func generateMessage(forDiff diff: String) async -> String? {
            callCount += 1
            return message
        }
    }

    // MARK: - Fixture helpers

    private func pollUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeFixtureRepo() throws -> String {
        try GitFixture.makeFixtureRepo(prefix: "supermux-ai-commit-tests")
    }

    private func lastCommitSubject(in root: String) throws -> String {
        try GitFixture.runGit(["log", "-1", "--pretty=%s"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

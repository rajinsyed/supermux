import Foundation
import Testing
@testable import SupermuxKit

/// Tests for the mobile `changes.generate_commit_message` core (validation
/// contract RPC-CHG-08): with no AI Gateway key configured (an EMPTY temp
/// state dir — never the user's real one) the outcome is a deterministic
/// `.unavailable` (the handler's `ai_unavailable` wire error), never a crash
/// or a silent empty message; and no outcome ever carries key material —
/// the generated message comes from the model reply alone.
// Serialized: shells out to real `git`. Alongside the other git-integration
// suites, subprocess concurrency can transiently drop a capture (an empty
// uncommitted diff reads as .nothingToDescribe — the shared CommandRunner
// partial/empty-read artifact); one full-suite rerun is the documented remedy.
@Suite(.serialized) struct SupermuxMobileCommitMessageTests {
    // MARK: - RPC-CHG-08

    @Test func reportsUnavailableWithoutAConfiguredKey() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-commitmsg-nokey")
        defer { GitFixture.cleanUp(repo) }
        try GitFixture.write("edited\n", to: "README.md", in: repo)

        // An empty temp state dir: the key file the app composition reads is
        // absent, so the real client chain reports unconfigured (the same
        // seam as the suggest_branch no-key test).
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-commitmsg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let keyURL = stateDir.appendingPathComponent(SupermuxAIConfig.secretFileName)
        let client = SupermuxAIGatewayClient(apiKeyProvider: {
            guard let value = try? String(contentsOf: keyURL, encoding: .utf8),
                  !value.isEmpty else { return nil }
            return value
        })

        let outcome = await SupermuxMobileCommitMessage.generate(
            repoPath: repo,
            service: SupermuxGitChangesService(),
            messenger: SupermuxAICommitMessenger(client: client)
        )

        #expect(outcome == .unavailable)
    }

    // MARK: - Configured paths

    @Test func generatesAMessageFromTheUncommittedDiff() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-commitmsg-gen")
        defer { GitFixture.cleanUp(repo) }
        try GitFixture.write("edited\n", to: "README.md", in: repo)
        let fake = FakeAICompleting(response: .success("docs: refresh the readme"))
        let messenger = SupermuxAICommitMessenger(client: fake, modelProvider: { "test-model" })

        let outcome = await SupermuxMobileCommitMessage.generate(
            repoPath: repo,
            service: SupermuxGitChangesService(),
            messenger: messenger
        )

        #expect(outcome == .generated("docs: refresh the readme"))
        // The model saw the change (the non-mutating uncommitted diff).
        #expect(await fake.lastUser?.contains("README.md") == true)
    }

    @Test func cleanRepositoryReportsNothingToDescribe() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-commitmsg-clean")
        defer { GitFixture.cleanUp(repo) }
        let fake = FakeAICompleting(response: .success("never used"))

        let outcome = await SupermuxMobileCommitMessage.generate(
            repoPath: repo,
            service: SupermuxGitChangesService(),
            messenger: SupermuxAICommitMessenger(client: fake)
        )

        #expect(outcome == .nothingToDescribe)
    }

    @Test func gatewayFailureReportsFailedNotACrash() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-commitmsg-fail")
        defer { GitFixture.cleanUp(repo) }
        try GitFixture.write("edited\n", to: "README.md", in: repo)
        let fake = FakeAICompleting(response: .failure(.requestFailed(status: 500, message: nil)))

        let outcome = await SupermuxMobileCommitMessage.generate(
            repoPath: repo,
            service: SupermuxGitChangesService(),
            messenger: SupermuxAICommitMessenger(client: fake)
        )

        #expect(outcome == .failed)
    }
}

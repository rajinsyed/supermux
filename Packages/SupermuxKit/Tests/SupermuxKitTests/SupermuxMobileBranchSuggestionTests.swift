import Foundation
import Testing
@testable import SupermuxKit

/// Tests for the mobile `worktree.suggest_branch` core (validation contract
/// RPC-WT-03): with no AI Gateway key configured (an EMPTY temp state dir —
/// never the user's real one) the suggestion falls back to a friendly random
/// name with `source: "random"`, never errors, and the wire payload carries
/// exactly `{branch_name, source}` — no key material.
struct SupermuxMobileBranchSuggestionTests {
    // MARK: - RPC-WT-03

    @Test func fallsBackToRandomWithoutAConfiguredKey() async throws {
        // An empty temp state dir: the key file the app composition reads is
        // absent, so the real client chain reports unconfigured.
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-mobile-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let keyURL = stateDir.appendingPathComponent(SupermuxAIConfig.secretFileName)
        let client = SupermuxAIGatewayClient(apiKeyProvider: {
            guard let value = try? String(contentsOf: keyURL, encoding: .utf8), !value.isEmpty else { return nil }
            return value
        })
        let namer = SupermuxAIBranchNamer(client: client)

        let suggestion = await SupermuxMobileBranchSuggestion.suggest(
            workspaceName: "Fix login flow",
            namer: namer
        )

        #expect(suggestion.source == .random)
        let parts = suggestion.branchName.split(separator: "-").map(String.init)
        #expect(parts.count == 2)
        #expect(SupermuxFriendlyWords.predicates.contains(try #require(parts.first)))
        #expect(SupermuxFriendlyWords.objects.contains(try #require(parts.last)))
    }

    @Test func wirePayloadCarriesExactlyBranchNameAndSource() async {
        let suggestion = await SupermuxMobileBranchSuggestion.suggest(workspaceName: nil, namer: nil)
        let payload = suggestion.wirePayload
        #expect(Set(payload.keys) == ["branch_name", "source"])
        #expect(payload["source"] as? String == "random")
        #expect(payload["branch_name"] as? String == suggestion.branchName)
    }

    // MARK: - AI path

    @Test func usesTheAINamerWhenConfigured() async {
        let fake = FakeAICompleting(response: .success("fix-login-redirect"))
        let namer = SupermuxAIBranchNamer(client: fake, modelProvider: { "test-model" })

        let suggestion = await SupermuxMobileBranchSuggestion.suggest(
            workspaceName: "Fix the login redirect",
            namer: namer
        )

        #expect(suggestion.source == .ai)
        #expect(suggestion.branchName == "fix-login-redirect")
        #expect(suggestion.wirePayload["source"] as? String == "ai")
    }

    @Test func blankWorkspaceNameFallsBackToRandomEvenWithAIConfigured() async {
        let fake = FakeAICompleting(response: .success("never-used"))
        let namer = SupermuxAIBranchNamer(client: fake)

        let suggestion = await SupermuxMobileBranchSuggestion.suggest(workspaceName: "   ", namer: namer)

        #expect(suggestion.source == .random)
        #expect(suggestion.branchName != "never-used")
    }

    @Test func aiFailureDegradesToRandomInsteadOfAnError() async {
        let fake = FakeAICompleting(response: .failure(.requestFailed(status: 500, message: nil)))
        let namer = SupermuxAIBranchNamer(client: fake)

        let suggestion = await SupermuxMobileBranchSuggestion.suggest(workspaceName: "Fix login", namer: namer)

        #expect(suggestion.source == .random)
        #expect(!suggestion.branchName.isEmpty)
    }
}

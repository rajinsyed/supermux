import Testing
@testable import SupermuxKit

/// Unit tests for ``SupermuxAIBranchNamer``: it sanitizes model output, takes a
/// single line, and degrades to `nil` (so callers fall back to a random name)
/// whenever AI is unavailable, the input is blank, the request fails, or the
/// output sanitizes to nothing.
struct SupermuxAIBranchNamerTests {
    @Test func passesCleanOutputThrough() async {
        let fake = FakeAICompleting(response: .success("fix-login-redirect"))
        let namer = SupermuxAIBranchNamer(client: fake, modelProvider: { "test-model" })
        #expect(await namer.suggestBranchName(forWorkspaceName: "fix login") == "fix-login-redirect")
    }

    @Test func sanitizesMessyOutput() async {
        let fake = FakeAICompleting(response: .success("Fix Login Bug!"))
        let namer = SupermuxAIBranchNamer(client: fake)
        #expect(await namer.suggestBranchName(forWorkspaceName: "x") == "Fix-Login-Bug")
    }

    @Test func usesOnlyFirstLine() async {
        let fake = FakeAICompleting(response: .success("fix-login\nHere is why…"))
        let namer = SupermuxAIBranchNamer(client: fake)
        #expect(await namer.suggestBranchName(forWorkspaceName: "x") == "fix-login")
    }

    /// Regression: a fenced reply used to yield "```" as the first line, which
    /// sanitized to `nil` and silently discarded the AI suggestion. The fence
    /// must be stripped first — with or without a language tag, and even for a
    /// single-line fenced reply.
    @Test func stripsCodeFenceBeforeTakingFirstLine() async {
        for reply in ["```\nfix-login\n```", "```text\nfix-login\n```", "```fix-login```"] {
            let fake = FakeAICompleting(response: .success(reply))
            let namer = SupermuxAIBranchNamer(client: fake)
            #expect(await namer.suggestBranchName(forWorkspaceName: "x") == "fix-login")
        }
    }

    @Test func forwardsResolvedModel() async {
        let fake = FakeAICompleting(response: .success("branch"))
        let namer = SupermuxAIBranchNamer(client: fake, modelProvider: { "anthropic/claude-haiku" })
        _ = await namer.suggestBranchName(forWorkspaceName: "x")
        #expect(await fake.lastModel == "anthropic/claude-haiku")
    }

    @Test func nilWhenNotConfigured() async {
        let fake = FakeAICompleting(configured: false, response: .success("whatever"))
        let namer = SupermuxAIBranchNamer(client: fake)
        #expect(await namer.suggestBranchName(forWorkspaceName: "x") == nil)
    }

    @Test func nilOnBlankInput() async {
        let fake = FakeAICompleting(response: .success("x"))
        let namer = SupermuxAIBranchNamer(client: fake)
        #expect(await namer.suggestBranchName(forWorkspaceName: "   ") == nil)
    }

    @Test func nilOnRequestError() async {
        let fake = FakeAICompleting(response: .failure(.requestFailed(status: 500, message: nil)))
        let namer = SupermuxAIBranchNamer(client: fake)
        #expect(await namer.suggestBranchName(forWorkspaceName: "x") == nil)
    }

    @Test func nilWhenOutputSanitizesToNothing() async {
        let fake = FakeAICompleting(response: .success("!!!"))
        let namer = SupermuxAIBranchNamer(client: fake)
        #expect(await namer.suggestBranchName(forWorkspaceName: "x") == nil)
    }
}

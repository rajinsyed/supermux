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

    /// Regression: reasoning models (e.g. `openai/gpt-5.6-luna`) spend
    /// completion tokens on hidden reasoning before emitting any text. The old
    /// 24-token budget was consumed entirely by reasoning, the gateway
    /// returned an empty reply with `finish_reason: "length"`, and every AI
    /// branch name silently fell back to a random name — "the AI stuff don't
    /// work". The budget must leave generous headroom for reasoning; the cap
    /// is a safety bound, not a billed amount.
    @Test func tokenBudgetLeavesRoomForReasoningModels() async {
        let fake = FakeAICompleting(response: .success("fix-login"))
        let namer = SupermuxAIBranchNamer(client: fake)
        _ = await namer.suggestBranchName(forWorkspaceName: "x")
        #expect(await fake.lastMaxTokens ?? 0 >= 512)
    }

    /// The workspace name is often a free-form problem description ("the app
    /// freezes when I drag a tab"), not an imperative task. The prompt must
    /// tell the model to name the branch after the fix so those inputs yield
    /// a proper slug instead of a literal restatement.
    @Test func systemPromptDirectsProblemDescriptionsTowardTheFix() async {
        let fake = FakeAICompleting(response: .success("fix-login"))
        let namer = SupermuxAIBranchNamer(client: fake)
        _ = await namer.suggestBranchName(forWorkspaceName: "x")
        #expect(await fake.lastSystem?.contains("name the branch after the fix") == true)
    }
}

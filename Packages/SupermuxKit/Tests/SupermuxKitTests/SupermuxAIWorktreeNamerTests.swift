import Testing
@testable import SupermuxKit

/// One AI call names both the workspace and the branch; every failure mode
/// returns `nil` so the caller falls back to the offline heuristic.
struct SupermuxAIWorktreeNamerTests {
    @Test func parsesTitleAndBranchFromJSON() async {
        let fake = FakeAICompleting(response: .success(#"{"title": "Fix Login Redirect", "branch": "fix-login-redirect"}"#))
        let namer = SupermuxAIWorktreeNamer(client: fake, modelProvider: { "test-model" })
        let names = await namer.suggestNames(forPrompt: "the login redirect is broken")
        #expect(names == SupermuxPromptNames(workspaceName: "Fix Login Redirect", branchName: "fix-login-redirect"))
        #expect(await fake.lastModel == "test-model")
        #expect(await fake.lastUser == "the login redirect is broken")
    }

    @Test func toleratesFencesProseAndMessyBranches() async {
        let fake = FakeAICompleting(response: .success(
            "Sure!\n```json\n{\"title\": \"Dark Mode Toggle\", \"branch\": \"Add Dark Mode!!\"}\n```"
        ))
        let namer = SupermuxAIWorktreeNamer(client: fake)
        let names = await namer.suggestNames(forPrompt: "x")
        #expect(names?.workspaceName == "Dark Mode Toggle")
        #expect(names?.branchName == "Add-Dark-Mode")
    }

    /// Prose with its own braces around (or inside) the object must not
    /// widen the slice into invalid JSON.
    @Test func extractsTheFirstDecodableObjectFromBracedProse() async {
        let fake = FakeAICompleting(response: .success(
            "Naming {task}: {\"title\": \"Fix {Brace} Parsing\", \"branch\": \"fix-brace-parsing\"} — see {notes}"
        ))
        let names = await SupermuxAIWorktreeNamer(client: fake).suggestNames(forPrompt: "x")
        #expect(names == SupermuxPromptNames(workspaceName: "Fix {Brace} Parsing", branchName: "fix-brace-parsing"))
    }

    @Test func derivesBranchFromTitleWhenMissing() async {
        let fake = FakeAICompleting(response: .success(#"{"title": "Retry Uploader"}"#))
        let names = await SupermuxAIWorktreeNamer(client: fake).suggestNames(forPrompt: "x")
        #expect(names?.branchName == "Retry-Uploader")
    }

    @Test func returnsNilWhenUnconfiguredBlankFailingOrMalformed() async {
        #expect(await SupermuxAIWorktreeNamer(client: FakeAICompleting(configured: false, response: .success("{}")))
            .suggestNames(forPrompt: "x") == nil)
        #expect(await SupermuxAIWorktreeNamer(client: FakeAICompleting(response: .success(#"{"title":"T"}"#)))
            .suggestNames(forPrompt: "   ") == nil)
        #expect(await SupermuxAIWorktreeNamer(client: FakeAICompleting(response: .failure(.notConfigured)))
            .suggestNames(forPrompt: "x") == nil)
        #expect(await SupermuxAIWorktreeNamer(client: FakeAICompleting(response: .success("not json")))
            .suggestNames(forPrompt: "x") == nil)
        #expect(await SupermuxAIWorktreeNamer(client: FakeAICompleting(response: .success(#"{"branch":"only"}"#)))
            .suggestNames(forPrompt: "x") == nil)
    }
}

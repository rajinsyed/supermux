import Testing
@testable import SupermuxKit

/// Unit tests for ``SupermuxAICommitMessenger``: diff clipping, code-fence
/// cleanup, and graceful `nil` results.
struct SupermuxAICommitMessengerTests {
    @Test func cleanupStripsCodeFences() {
        #expect(SupermuxAICommitMessenger.cleanup("```\nfeat: add x\n```") == "feat: add x")
        #expect(SupermuxAICommitMessenger.cleanup("```text\nfix: y\n\nbody\n```") == "fix: y\n\nbody")
    }

    @Test func cleanupLeavesPlainMessage() {
        #expect(SupermuxAICommitMessenger.cleanup("feat: plain message") == "feat: plain message")
    }

    @Test func clipTruncatesLongDiffs() {
        let long = String(repeating: "a", count: SupermuxAICommitMessenger.maxDiffCharacters + 500)
        let clipped = SupermuxAICommitMessenger.clip(long)
        #expect(clipped.count < long.count)
        #expect(clipped.hasSuffix("[diff truncated]"))
    }

    @Test func clipLeavesShortDiffs() {
        #expect(SupermuxAICommitMessenger.clip("short diff") == "short diff")
    }

    @Test func generatesMessage() async {
        let fake = FakeAICompleting(response: .success("feat: add a thing"))
        let messenger = SupermuxAICommitMessenger(client: fake)
        #expect(await messenger.generateMessage(forDiff: "diff --git a b") == "feat: add a thing")
    }

    @Test func nilWhenNotConfigured() async {
        let fake = FakeAICompleting(configured: false, response: .success("feat: x"))
        let messenger = SupermuxAICommitMessenger(client: fake)
        #expect(await messenger.generateMessage(forDiff: "diff") == nil)
    }

    @Test func nilOnEmptyDiff() async {
        let fake = FakeAICompleting(response: .success("feat: x"))
        let messenger = SupermuxAICommitMessenger(client: fake)
        #expect(await messenger.generateMessage(forDiff: "   ") == nil)
    }

    @Test func nilWhenModelReturnsOnlyFence() async {
        let fake = FakeAICompleting(response: .success("```\n```"))
        let messenger = SupermuxAICommitMessenger(client: fake)
        #expect(await messenger.generateMessage(forDiff: "diff --git a b") == nil)
    }

    @Test func nilOnRequestError() async {
        let fake = FakeAICompleting(response: .failure(.transport("offline")))
        let messenger = SupermuxAICommitMessenger(client: fake)
        #expect(await messenger.generateMessage(forDiff: "diff") == nil)
    }
}

import Testing
@testable import SupermuxKit

/// Unit tests for ``SupermuxAICommitMessenger``: diff clipping, code-fence
/// cleanup, and graceful `nil` results.
struct SupermuxAICommitMessengerTests {
    @Test func cleanupStripsCodeFences() {
        #expect(SupermuxAICommitMessenger.cleanup("```\nfeat: add x\n```") == "feat: add x")
        #expect(SupermuxAICommitMessenger.cleanup("```text\nfix: y\n\nbody\n```") == "fix: y\n\nbody")
    }

    /// Regression: a language tag followed by trailing whitespace ("```text \n"
    /// — a common model artifact) must still be recognized as a tag and
    /// dropped, not committed as the message's literal first line "text".
    @Test func cleanupStripsLanguageTagWithTrailingWhitespace() {
        #expect(SupermuxAICommitMessenger.cleanup("```text \nfix: y\n```") == "fix: y")
        #expect(SupermuxAICommitMessenger.cleanup("```markdown\t\nfix: y\n```") == "fix: y")
        // Real content on the fence line still survives (interior spaces and
        // punctuation are not tag characters).
        #expect(SupermuxAICommitMessenger.cleanup("```fix: x \n```") == "fix: x")
    }

    /// Regression: a fenced reply whose content shares a line with the fence
    /// must keep the content. The old line-removal cleanup deleted the whole
    /// line, turning a valid single-line reply into "" (a spurious
    /// "generation failed" error).
    @Test func cleanupPreservesContentOnFenceLine() {
        #expect(SupermuxAICommitMessenger.cleanup("```fix: x```") == "fix: x")
        #expect(SupermuxAICommitMessenger.cleanup("```fix: x\n```") == "fix: x")
        #expect(SupermuxAICommitMessenger.cleanup("```\nfix: x```") == "fix: x")
    }

    @Test func cleanupLeavesPlainMessage() {
        #expect(SupermuxAICommitMessenger.cleanup("feat: plain message") == "feat: plain message")
    }

    /// Regression: a single-line fenced reply whose content ends in inline
    /// code must keep the content's own backtick — only the fence's matching
    /// backtick run is stripped, never a longer run.
    @Test func cleanupKeepsInlineCodeBacktickAtEndOfFencedContent() {
        #expect(SupermuxAICommitMessenger.cleanup("```fix: escape `$HOME````") == "fix: escape `$HOME`")
    }

    /// Regression: a truncated reply that opens a fence but never closes it
    /// keeps a trailing content backtick (the run is shorter than the opening
    /// fence, so it is content, not a closing fence).
    @Test func cleanupKeepsTrailingContentBacktickInTruncatedFence() {
        #expect(SupermuxAICommitMessenger.cleanup("```\nfix: quote `$PATH`") == "fix: quote `$PATH`")
    }

    /// End-to-end: a single-line fenced gateway reply yields a usable message,
    /// not `nil`.
    @Test func generatesMessageFromSingleLineFencedReply() async {
        let fake = FakeAICompleting(response: .success("```fix: update parser```"))
        let messenger = SupermuxAICommitMessenger(client: fake)
        #expect(await messenger.generateMessage(forDiff: "diff --git a b") == "fix: update parser")
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

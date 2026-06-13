import SupermuxKit
import Testing

/// Unit tests for `SupermuxBranchName`: sanitization, collision-free
/// deduplication, and worktree directory naming.
struct SupermuxBranchNameTests {
    private let naming = SupermuxBranchName()

    // MARK: - sanitize

    @Test func sanitizeReplacesSpacesWithDashes() {
        #expect(naming.sanitize("Fix login bug") == "Fix-login-bug")
    }

    @Test func sanitizeDropsDisallowedCharacters() {
        #expect(naming.sanitize("fix: login (bug)!") == "fix-login-bug")
    }

    @Test func sanitizeCollapsesRepeatedSeparators() {
        #expect(naming.sanitize("a--b") == "a-b")
        #expect(naming.sanitize("a---b") == "a-b")
        #expect(naming.sanitize("a..b") == "a.b")
        #expect(naming.sanitize("a//b") == "a/b")
        #expect(naming.sanitize("a - b") == "a-b")
    }

    @Test func sanitizeTrimsLeadingAndTrailingSeparators() {
        #expect(naming.sanitize("-foo-") == "foo")
        #expect(naming.sanitize("./feature/foo/") == "feature/foo")
        #expect(naming.sanitize("--bar..") == "bar")
    }

    @Test func sanitizeReturnsNilForUnusableInput() {
        #expect(naming.sanitize("") == nil)
        #expect(naming.sanitize("   ") == nil)
        #expect(naming.sanitize("!!! ???") == nil)
        #expect(naming.sanitize("-./") == nil)
    }

    @Test func sanitizeCapsLengthAtMaximum() {
        let long = String(repeating: "a", count: 150)
        #expect(naming.sanitize(long) == String(repeating: "a", count: SupermuxBranchName.maxLength))
    }

    @Test func sanitizeTrimsSeparatorLeftDanglingByTruncation() {
        // Character 100 is a dash, so the cap leaves a trailing "-" that the
        // final trim must remove.
        let head = String(repeating: "a", count: SupermuxBranchName.maxLength - 1)
        let input = head + "-" + String(repeating: "b", count: 50)
        #expect(naming.sanitize(input) == head)
    }

    @Test func sanitizePreservesSlashSeparatedNames() {
        #expect(naming.sanitize("feature/foo") == "feature/foo")
    }

    // MARK: - deduplicate

    @Test func deduplicateReturnsCandidateWhenFree() {
        #expect(naming.deduplicate("foo", existing: ["bar", "baz"]) == "foo")
        #expect(naming.deduplicate("foo", existing: []) == "foo")
    }

    @Test func deduplicateAppendsNumericSuffixOnCollision() {
        #expect(naming.deduplicate("foo", existing: ["foo"]) == "foo-2")
        #expect(naming.deduplicate("foo", existing: ["foo", "foo-2"]) == "foo-3")
    }

    @Test func deduplicateComparesCaseInsensitively() {
        #expect(naming.deduplicate("Foo", existing: ["foo"]) == "Foo-2")
        #expect(naming.deduplicate("foo", existing: ["FOO", "Foo-2"]) == "foo-3")
    }

    @Test func deduplicateKeepsSuffixedNamesWithinMaxLength() {
        let candidate = String(repeating: "a", count: SupermuxBranchName.maxLength)
        var existing = [candidate]

        let first = naming.deduplicate(candidate, existing: existing)
        #expect(first.count <= SupermuxBranchName.maxLength)
        #expect(first.hasSuffix("-2"))
        #expect(!existing.map { $0.lowercased() }.contains(first.lowercased()))

        existing.append(first)
        let second = naming.deduplicate(candidate, existing: existing)
        #expect(second.count <= SupermuxBranchName.maxLength)
        #expect(second.hasSuffix("-3"))
        #expect(!existing.map { $0.lowercased() }.contains(second.lowercased()))
    }

    // MARK: - directoryComponent

    @Test func directoryComponentReplacesSlashesWithDashes() {
        #expect(naming.directoryComponent(for: "feature/foo") == "feature-foo")
        #expect(naming.directoryComponent(for: "plain") == "plain")
    }

    // MARK: - randomName

    @Test func randomNameProducesSanitizedTwoWordName() {
        for _ in 0..<300 {
            let name = naming.randomName()
            // Exactly two non-empty words joined by a single dash.
            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
            #expect(parts.count == 2)
            #expect(parts.allSatisfy { !$0.isEmpty })
            // The generated name is already git-safe: sanitizing is a no-op.
            #expect(naming.sanitize(name) == name)
        }
    }

    @Test func randomNameIsDeterministicForSeededGenerator() {
        var a = SeededGenerator(seed: 0x5EED_CAFE)
        var b = SeededGenerator(seed: 0x5EED_CAFE)
        #expect(naming.randomName(using: &a) == naming.randomName(using: &b))
    }
}

/// A tiny deterministic `RandomNumberGenerator` (xorshift64) so the seeded
/// `randomName(using:)` overload can be exercised reproducibly in tests.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

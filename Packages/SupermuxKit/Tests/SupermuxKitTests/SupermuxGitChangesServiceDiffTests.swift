import Foundation
import Testing

@testable import SupermuxKit

/// Integration tests, against real temporary git repositories, for the parts
/// of `SupermuxGitChangesService` added alongside the `-z` status parsing and
/// the byte-capped AI diff: verbatim non-ASCII paths end-to-end, and
/// `uncommittedDiff`'s bounded patch capture.
///
/// Split from `SupermuxGitChangesServiceTests` (which sits at its file-length
/// budget). Serialized for the same reason as that suite: it shells out to
/// real `git`.
@Suite(.serialized) struct SupermuxGitChangesServiceDiffTests {
    private let service = SupermuxGitChangesService()

    // MARK: - Non-ASCII paths (porcelain -z)

    /// Without `-z`, git C-quotes any non-ASCII filename
    /// (`"r\303\251sum\303\251.txt"`), which mangled display and broke every
    /// mutation built from the parsed path. The `-z` invocation must round-trip
    /// the path verbatim through status → stage → status.
    @Test func nonASCIIFilenameRoundTripsThroughStatusAndStage() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("bonjour\n", to: "résumé.txt", in: root)

        let before = await service.status(repoPath: root)
        let untracked = try #require(before.untracked.first)
        #expect(untracked.path == "résumé.txt")

        try await service.stage(repoPath: root, paths: [untracked.path])

        let after = await service.status(repoPath: root)
        let staged = try #require(after.staged.first)
        #expect(staged.path == "résumé.txt")
        #expect(staged.kind == .added)
        #expect(after.untracked.isEmpty)
    }

    // MARK: - Bounded AI diff

    @Test func uncommittedDiffContainsStatPatchAndUntracked() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("changed\n", to: "README.md", in: root)
        try GitFixture.write("fresh\n", to: "brand-new.txt", in: root)

        let diff = await service.uncommittedDiff(repoPath: root)

        #expect(diff.contains("README.md"))          // stat + patch
        #expect(diff.contains("+changed"))           // patch body
        #expect(diff.contains("New untracked files:"))
        #expect(diff.contains("brand-new.txt"))
    }

    /// A huge patch must be capped at the pipe, not captured whole: the result
    /// stays near `maxAIPatchBytes` (plus the small stat/untracked sections)
    /// instead of the multi-hundred-KB raw patch.
    @Test func uncommittedDiffCapsHugePatch() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        // Commit a file, then rewrite it with ~600 KB of changed lines.
        try GitFixture.write("v1\n", to: "big.txt", in: root)
        try GitFixture.runGit(["add", "big.txt"], in: root)
        try GitFixture.runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Add big"], in: root)
        let hugeContent = (0..<20_000).map { "line \($0): \(String(repeating: "x", count: 24))" }
            .joined(separator: "\n")
        try GitFixture.write(hugeContent, to: "big.txt", in: root)

        let diff = await service.uncommittedDiff(repoPath: root)

        #expect(!diff.isEmpty)
        #expect(diff.contains("big.txt"))
        // Cap plus generous headroom for the stat section.
        #expect(diff.utf8.count < SupermuxGitChangesService.maxAIPatchBytes + 16_384)
    }

    /// The byte cap can split a multibyte character; the pipeline must still
    /// yield a valid (non-nil, non-empty) UTF-8 patch rather than dropping it.
    @Test func uncommittedDiffSurvivesMultibyteContentAtTheCap() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("v1\n", to: "unicode.txt", in: root)
        try GitFixture.runGit(["add", "unicode.txt"], in: root)
        try GitFixture.runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Add unicode"], in: root)
        // Multibyte content larger than the cap, so the cut lands mid-character
        // somewhere with overwhelming probability.
        let multibyte = String(repeating: "é漢字🚀", count: 12_000)
        try GitFixture.write(multibyte, to: "unicode.txt", in: root)

        let diff = await service.uncommittedDiff(repoPath: root)

        #expect(!diff.isEmpty)
        #expect(diff.contains("unicode.txt"))
        #expect(diff.utf8.count < SupermuxGitChangesService.maxAIPatchBytes + 16_384)
    }

    // MARK: - Untracked content digest

    /// The digest is the staleness signal for untracked-file *content*: the
    /// AI diff lists untracked files by name only, so a same-name rewrite must
    /// change the digest (mtime/size) while an untouched tree keeps it stable.
    @Test func untrackedContentDigestTracksContentChanges() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }

        // Clean tree: no untracked files → empty digest.
        let clean = await service.untrackedContentDigest(repoPath: root)
        #expect(clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try GitFixture.write("v1\n", to: "notes.txt", in: root)
        let first = await service.untrackedContentDigest(repoPath: root)
        // Opaque token (base64-armored stat lines) — non-empty once an
        // untracked file exists.
        #expect(!first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Unchanged tree → identical digest (no false regenerations).
        let second = await service.untrackedContentDigest(repoPath: root)
        #expect(second == first)

        // Same filename, new bytes → different digest.
        try GitFixture.write("v2 rewritten\n", to: "notes.txt", in: root)
        let third = await service.untrackedContentDigest(repoPath: root)
        #expect(third != first)
    }

    /// A root-level untracked file named `-config` must not be parsed as
    /// `stat` options: without the `--` terminator it failed the ENTIRE xargs
    /// batch and emptied the digest, blinding the staleness guard for every
    /// untracked file at once.
    @Test func untrackedContentDigestSurvivesDashPrefixedFilename() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("dash v1\n", to: "-config", in: root)
        try GitFixture.write("normal\n", to: "normal.txt", in: root)

        let first = await service.untrackedContentDigest(repoPath: root)
        #expect(!first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(first != "untracked-digest-unavailable")

        // Rewriting the dash-named file must register as a digest change.
        try GitFixture.write("dash v2 rewritten\n", to: "-config", in: root)
        let second = await service.untrackedContentDigest(repoPath: root)
        #expect(second != "untracked-digest-unavailable")
        #expect(second != first)
    }

    // MARK: - Tracked diff digest

    /// The model-facing patch is capped at `maxAIPatchBytes`, so an edit to a
    /// file whose diff section lies past the cap changes neither the patch nor
    /// the `--stat` summary — the full-diff digest is the staleness identity
    /// that must still see it.
    @Test func trackedDiffDigestSeesEditsPastThePatchCap() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        // `aaa_big.txt` sorts first in the diff and its rewrite blows past the
        // byte cap, pushing `zzz_tail.txt`'s hunk beyond it.
        try GitFixture.write("v1\n", to: "aaa_big.txt", in: root)
        try GitFixture.write("v1\n", to: "zzz_tail.txt", in: root)
        try GitFixture.runGit(["add", "aaa_big.txt", "zzz_tail.txt"], in: root)
        try GitFixture.runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Add big and tail"], in: root)
        let hugeContent = (0..<20_000).map { "line \($0): \(String(repeating: "x", count: 24))" }
            .joined(separator: "\n")
        try GitFixture.write(hugeContent, to: "aaa_big.txt", in: root)
        try GitFixture.write("edit alpha\n", to: "zzz_tail.txt", in: root)

        let diffBefore = await service.uncommittedDiff(repoPath: root)
        let digestBefore = await service.trackedDiffDigest(repoPath: root)
        #expect(!digestBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(digestBefore != "tracked-digest-unavailable")
        // The tail file's hunk lies past the cap: its content never reaches
        // the model-facing patch.
        #expect(!diffBefore.contains("edit alpha"))

        // Unchanged tree → stable digest (no false regenerations).
        #expect(await service.trackedDiffDigest(repoPath: root) == digestBefore)

        // Same-line rewrite: identical stat counts and a hunk still past the
        // cap, so the capped diff cannot change — only the digest can.
        try GitFixture.write("edit bravo\n", to: "zzz_tail.txt", in: root)
        let diffAfter = await service.uncommittedDiff(repoPath: root)
        let digestAfter = await service.trackedDiffDigest(repoPath: root)
        #expect(diffAfter == diffBefore)
        #expect(digestAfter != digestBefore)
    }

    // MARK: - Fixture helpers (shared implementation in `GitFixture`)

    private func makeFixtureRepo() throws -> String {
        try GitFixture.makeFixtureRepo(prefix: "supermux-diff-tests")
    }
}

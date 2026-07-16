import Foundation
import Testing

@testable import SupermuxKit

/// Integration tests, against real temporary git repositories, for the
/// per-file diff capture behind `mobile.supermux.changes.diff`
/// (validation contract RPC-CHG-02): unified diff text for text files,
/// `isBinary` with no text for binary files, staged/unstaged selection,
/// untracked-file previews, and byte-cap truncation.
@Suite(.serialized) struct SupermuxGitChangesFileDiffTests {
    private let service = SupermuxGitChangesService()

    private func makeFixtureRepo() throws -> String {
        try GitFixture.makeFixtureRepo(prefix: "supermux-file-diff")
    }

    /// Writes raw bytes (including NULs, so git treats the file as binary).
    private func writeData(_ data: Data, to relativePath: String, in root: String) throws {
        let path = (root as NSString).appendingPathComponent(relativePath)
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - RPC-CHG-02: text file → unified diff text

    @Test func modifiedTextFileYieldsUnifiedDiffText() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("changed\n", to: "README.md", in: root)

        let diff = await service.fileDiff(repoPath: root, path: "README.md", staged: false)

        #expect(diff.isBinary == false)
        #expect(diff.truncated == false)
        let text = try #require(diff.text)
        #expect(text.contains("@@"))
        #expect(text.contains("-fixture"))
        #expect(text.contains("+changed"))
    }

    @Test func stagedFlagSelectsTheIndexDiff() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("staged change\n", to: "README.md", in: root)
        try GitFixture.runGit(["add", "README.md"], in: root)

        let staged = await service.fileDiff(repoPath: root, path: "README.md", staged: true)
        let unstaged = await service.fileDiff(repoPath: root, path: "README.md", staged: false)

        #expect(staged.text?.contains("+staged change") == true)
        // Everything is staged, so the worktree-vs-index diff is empty.
        #expect(unstaged.text?.isEmpty == true)
        #expect(unstaged.isBinary == false)
    }

    // MARK: - RPC-CHG-02: binary file → is_binary, no diff text

    @Test func modifiedBinaryFileYieldsIsBinaryWithNoText() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try writeData(Data([0x00, 0x01, 0x02, 0xFF, 0x00]), to: "blob.bin", in: root)
        try GitFixture.runGit(["add", "blob.bin"], in: root)
        try GitFixture.commit("Add binary", in: root)
        try writeData(Data([0x00, 0xAA, 0xBB, 0x00, 0xCC]), to: "blob.bin", in: root)

        let diff = await service.fileDiff(repoPath: root, path: "blob.bin", staged: false)

        #expect(diff.isBinary == true)
        #expect(diff.text == nil)
        #expect(diff.truncated == false)
    }

    @Test func untrackedBinaryFileYieldsIsBinary() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try writeData(Data([0x00, 0x10, 0x20, 0x00]), to: "new.bin", in: root)

        let diff = await service.fileDiff(repoPath: root, path: "new.bin", staged: false)

        #expect(diff.isBinary == true)
        #expect(diff.text == nil)
    }

    // MARK: - Untracked text preview

    @Test func untrackedTextFileYieldsFullAdditionDiff() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("hello mobile\n", to: "fresh.txt", in: root)

        let diff = await service.fileDiff(repoPath: root, path: "fresh.txt", staged: false)

        #expect(diff.isBinary == false)
        let text = try #require(diff.text)
        #expect(text.contains("+hello mobile"))
    }

    @Test func gitignoredFileIsNotPreviewedAndLeaksNothing() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        // A gitignored secret is "not in the index" but is NOT a change the
        // Changes screen shows — previewing its bytes would leak a file the
        // user never staged. The untracked preview must gate on the real
        // untracked set (`ls-files --others --exclude-standard`), not merely
        // "absent from the index".
        try GitFixture.write(".env\n", to: ".gitignore", in: root)
        try GitFixture.runGit(["add", ".gitignore"], in: root)
        try GitFixture.commit("Ignore .env", in: root)
        try GitFixture.write("SECRET_TOKEN=topsecret\n", to: ".env", in: root)

        let diff = await service.fileDiff(repoPath: root, path: ".env", staged: false)

        #expect((diff.text ?? "").contains("topsecret") == false)
        #expect((diff.text ?? "").isEmpty)
    }

    @Test func gitInternalFileIsNotPreviewedAndLeaksNothing() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        // `.git/config` is inside the repo root but is a git internal, never a
        // user change — it must not be dumped via the untracked preview.
        let diff = await service.fileDiff(repoPath: root, path: ".git/config", staged: false)

        #expect((diff.text ?? "").contains("[core]") == false)
        #expect((diff.text ?? "").isEmpty)
    }

    // MARK: - Repository confinement (arbitrary-file-read hardening)

    @Test func escapingPathIsNotPreviewedAndLeaksNothing() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        // A secret file OUTSIDE the repository (a sibling of the repo dir).
        let secretName = "supermux-diff-secret-\(UUID().uuidString).txt"
        let secretPath = ((root as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(secretName)
        try "TOPSECRET".write(toFile: secretPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: secretPath) }

        // A `..`-escaping path must not be classified untracked and dumped via
        // `git diff --no-index` (which reads any file the user can read). The
        // capture must confine to the repo — empty text, no leak.
        let diff = await service.fileDiff(repoPath: root, path: "../\(secretName)", staged: false)

        #expect(diff.isBinary == false)
        #expect((diff.text ?? "").contains("TOPSECRET") == false)
        #expect((diff.text ?? "").isEmpty)
    }

    @Test func absolutePathIsNotPreviewedAndLeaksNothing() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        let secretPath = "/etc/hosts"

        // An absolute path is likewise never treated as an untracked entry.
        let diff = await service.fileDiff(repoPath: root, path: secretPath, staged: false)

        #expect(diff.isBinary == false)
        #expect((diff.text ?? "").isEmpty)
    }

    @Test func untrackedFileThroughInteriorSymlinkPreviewsResolvedTarget() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: (root as NSString).appendingPathComponent("real"),
            withIntermediateDirectories: true
        )
        try GitFixture.write("inside body\n", to: "real/note.txt", in: root)
        // `link -> real` stays inside the repo; the preview follows it to the
        // resolved target and still shows the content (no false rejection).
        try fm.createSymbolicLink(
            atPath: (root as NSString).appendingPathComponent("link"),
            withDestinationPath: (root as NSString).appendingPathComponent("real")
        )

        let diff = await service.fileDiff(repoPath: root, path: "link/note.txt", staged: false)

        #expect((diff.text ?? "").contains("+inside body"))
    }

    @Test func gitignoredFileReachedThroughASymlinkAliasIsNotPreviewed() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        // An ignored secret, plus an untracked symlink alias to it. The alias
        // itself is neither ignored nor tracked, so a check on the request path
        // alone would preview it; the ignore rule must follow the RESOLVED
        // target (`.env`) and refuse.
        try GitFixture.write(".env\n", to: ".gitignore", in: root)
        try GitFixture.runGit(["add", ".gitignore"], in: root)
        try GitFixture.commit("Ignore .env", in: root)
        try GitFixture.write("SECRET_TOKEN=topsecret\n", to: ".env", in: root)
        try FileManager.default.createSymbolicLink(
            atPath: (root as NSString).appendingPathComponent("leak"),
            withDestinationPath: (root as NSString).appendingPathComponent(".env")
        )

        let diff = await service.fileDiff(repoPath: root, path: "leak", staged: false)

        #expect((diff.text ?? "").contains("topsecret") == false)
        #expect((diff.text ?? "").isEmpty)
    }

    @Test func untrackedSymlinkEscapingRootLeaksNothing() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        let secret = ((root as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("supermux-diff-outside-\(UUID().uuidString).txt")
        try "TOPSECRET".write(toFile: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: secret) }
        // An untracked symlink whose target resolves OUTSIDE the root must not
        // have that target dumped — it resolves out of the repo, so it is never
        // previewed via `--no-index`.
        try FileManager.default.createSymbolicLink(
            atPath: (root as NSString).appendingPathComponent("escape.txt"),
            withDestinationPath: secret
        )

        let diff = await service.fileDiff(repoPath: root, path: "escape.txt", staged: false)

        #expect((diff.text ?? "").contains("TOPSECRET") == false)
    }

    // MARK: - Truncation

    @Test func hugeDiffIsByteCappedAndFlaggedTruncated() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("v1\n", to: "big.txt", in: root)
        try GitFixture.runGit(["add", "big.txt"], in: root)
        try GitFixture.commit("Add big", in: root)
        let hugeContent = (0..<20_000)
            .map { "line \($0): \(String(repeating: "x", count: 24))" }
            .joined(separator: "\n")
        try GitFixture.write(hugeContent, to: "big.txt", in: root)

        let diff = await service.fileDiff(repoPath: root, path: "big.txt", staged: false)

        #expect(diff.truncated == true)
        let text = try #require(diff.text)
        #expect(!text.isEmpty)
        #expect(text.utf8.count <= SupermuxGitChangesService.maxFileDiffBytes)
    }

    // MARK: - Paths that need shell quoting

    @Test func pathWithSpacesAndQuotesRoundTrips() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        let tricky = "my 'notes' file.txt"
        try GitFixture.write("draft\n", to: tricky, in: root)

        let diff = await service.fileDiff(repoPath: root, path: tricky, staged: false)

        #expect(diff.isBinary == false)
        #expect(diff.text?.contains("+draft") == true)
    }

    // MARK: - Unchanged path → empty diff

    @Test func unchangedPathYieldsEmptyDiffText() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }

        let diff = await service.fileDiff(repoPath: root, path: "README.md", staged: false)

        #expect(diff.isBinary == false)
        #expect(diff.text?.isEmpty == true)
        #expect(diff.truncated == false)
    }
}

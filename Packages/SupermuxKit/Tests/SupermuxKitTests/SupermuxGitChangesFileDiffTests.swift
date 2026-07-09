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

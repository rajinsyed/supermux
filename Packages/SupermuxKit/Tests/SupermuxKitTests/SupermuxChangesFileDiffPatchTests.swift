import Foundation
import Testing

@testable import SupermuxKit

/// Behavior tests, against real temporary git repositories, for the patch
/// capture behind a click on a Changes-panel file row
/// (`SupermuxChangesModel.fileDiffPatch(for:staged:)`).
@MainActor
@Suite(.serialized) struct SupermuxChangesFileDiffPatchTests {

    private func makeModel(at root: String) async -> SupermuxChangesModel {
        let model = SupermuxChangesModel(service: SupermuxGitChangesService())
        model.setDirectory(root)
        await model.refresh()
        return model
    }

    private func change(_ path: String, kind: SupermuxGitFileChange.Kind = .modified) -> SupermuxGitFileChange {
        SupermuxGitFileChange(path: path, oldPath: nil, kind: kind)
    }

    @Test func unstagedRowYieldsTheWorkingTreePatch() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-file-patch")
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("changed\n", to: "README.md", in: root)
        let model = await makeModel(at: root)

        let patch = try #require(await model.fileDiffPatch(for: change("README.md"), staged: false))

        #expect(patch.repoPath == root)
        #expect(patch.staged == false)
        #expect(patch.truncated == false)
        #expect(patch.patch.contains("+changed"))
        #expect(patch.title == "README.md")
        #expect(model.lastError == nil)
    }

    @Test func stagedRowYieldsTheIndexPatchWithAStagedTitle() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-file-patch")
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("staged\n", to: "README.md", in: root)
        try GitFixture.runGit(["add", "README.md"], in: root)
        let model = await makeModel(at: root)

        let patch = try #require(await model.fileDiffPatch(for: change("README.md"), staged: true))

        #expect(patch.staged == true)
        #expect(patch.patch.contains("+staged"))
        #expect(patch.title.hasPrefix("README.md"))
        #expect(patch.title != "README.md")
    }

    @Test func untrackedRowPreviewsAFullAddition() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-file-patch")
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("fresh\n", to: "fresh.txt", in: root)
        let model = await makeModel(at: root)

        let patch = try #require(await model.fileDiffPatch(for: change("fresh.txt", kind: .untracked), staged: false))

        #expect(patch.patch.contains("+++ b/fresh.txt"))
        #expect(patch.patch.contains("+fresh"))
    }

    @Test func binaryFileReportsAnErrorInsteadOfAPatch() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-file-patch")
        defer { GitFixture.cleanUp(root) }
        let blob = (root as NSString).appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0xFF]).write(to: URL(fileURLWithPath: blob))
        let model = await makeModel(at: root)

        let patch = await model.fileDiffPatch(for: change("blob.bin", kind: .untracked), staged: false)

        #expect(patch == nil)
        #expect(model.lastError?.contains("blob.bin") == true)
    }

    /// A row whose file no longer differs (stale status) reports an error and
    /// refreshes so the list catches up.
    @Test func emptyDiffReportsAnErrorAndRefreshes() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-file-patch")
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("changed\n", to: "README.md", in: root)
        let model = await makeModel(at: root)
        #expect(model.snapshot.totalChangeCount == 1)
        try GitFixture.runGit(["checkout", "--", "README.md"], in: root)

        let patch = await model.fileDiffPatch(for: change("README.md"), staged: false)

        #expect(patch == nil)
        #expect(model.lastError?.contains("README.md") == true)
        #expect(model.snapshot.totalChangeCount == 0)
    }

    @Test func noDirectoryYieldsNothing() async {
        let model = SupermuxChangesModel(service: SupermuxGitChangesService())

        let patch = await model.fileDiffPatch(for: change("README.md"), staged: false)

        #expect(patch == nil)
        #expect(model.lastError == nil)
    }
}

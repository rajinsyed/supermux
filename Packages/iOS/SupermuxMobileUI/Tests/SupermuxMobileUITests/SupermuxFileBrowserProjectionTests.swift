import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The file-browser UI's pure logic: the workspace-tools capability gate
/// (UI-02 for this mount), row-snapshot projection, error-text mapping, the
/// folder picker's path arithmetic, and the section model's picker seam.
@MainActor
@Suite struct SupermuxFileBrowserProjectionTests {
    private let wait = TestWait()

    // MARK: Toolbar entry gate (UI-02 for this mount)

    @Test func filesEntryRequiresALiveConnectionAdvertisingFilesV1() {
        #expect(!SupermuxWorkspaceTools.showsFilesEntry(hostCapabilities: nil))
        #expect(!SupermuxWorkspaceTools.showsFilesEntry(hostCapabilities: []))
        #expect(!SupermuxWorkspaceTools.showsFilesEntry(
            hostCapabilities: ["workspace.groups.v1", "supermux.changes.v1"]
        ))
        #expect(SupermuxWorkspaceTools.showsFilesEntry(
            hostCapabilities: ["supermux.files.v1"]
        ))
    }

    // MARK: Row projection

    @Test func rowSnapshotsPreserveOrderAndClassifyEntries() {
        let rows = SupermuxFileRowSnapshot.rows(from: [
            SupermuxFileEntryDTO(name: "src", isDir: true, isSymlink: false),
            SupermuxFileEntryDTO(name: "link", isDir: false, isSymlink: true),
            SupermuxFileEntryDTO(name: "notes.md", isDir: false, isSymlink: false, size: 2048),
        ])
        #expect(rows.map(\.name) == ["src", "link", "notes.md"])
        #expect(rows[0].isDirectory)
        #expect(rows[0].sizeText == nil)
        #expect(rows[0].iconSystemName == "folder")
        #expect(rows[1].isSymlink)
        #expect(rows[1].iconSystemName == "link")
        #expect(rows[2].iconSystemName == "doc.text")
        #expect(rows[2].sizeText?.isEmpty == false)
    }

    @Test func directoriesNeverShowASizeEvenWhenTheWireCarriesOne() {
        let row = SupermuxFileRowSnapshot(
            entry: SupermuxFileEntryDTO(name: "dir", isDir: true, isSymlink: false, size: 64)
        )
        #expect(row.sizeText == nil)
    }

    // MARK: Error text mapping

    @Test func nameIssuesMapToDedicatedLocalizedCopy() {
        let empty = SupermuxFileOpErrorText.message(
            for: SupermuxInvalidFileNameError(issue: .empty, name: "")
        )
        #expect(!empty.isEmpty)
        let slash = SupermuxFileOpErrorText.message(
            for: SupermuxInvalidFileNameError(issue: .containsSlash, name: "a/b")
        )
        #expect(slash.contains("a/b"))
    }

    @Test func wireErrorsSurfaceTheMacMessageVerbatim() {
        let message = SupermuxFileOpErrorText.message(
            for: MobileShellConnectionError.rpcError(
                "invalid_params", "Path escapes the resolved root: escape/evil.txt"
            )
        )
        #expect(message == "Path escapes the resolved root: escape/evil.txt")
    }

    // MARK: Folder-picker path arithmetic

    @Test func pickedAbsolutePathJoinsRootAndRelativePath() {
        #expect(SupermuxFolderPickerPath.absolutePath(
            rootPath: "/Users/dev/alpha", relativePath: ""
        ) == "/Users/dev/alpha")
        #expect(SupermuxFolderPickerPath.absolutePath(
            rootPath: "/Users/dev/alpha", relativePath: "packages/core"
        ) == "/Users/dev/alpha/packages/core")
        #expect(SupermuxFolderPickerPath.absolutePath(
            rootPath: "/Users/dev/alpha/", relativePath: "docs"
        ) == "/Users/dev/alpha/docs")
    }

    // MARK: Section model picker seam

    @Test func withoutFilesV1TheEditingSeamOffersNoPicker() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [
            SupermuxProjectDTO(id: "p-1", name: "Alpha", rootPath: "/Users/dev/alpha"),
        ])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [SupermuxMobileCapability.projectsV1.rawValue]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        #expect(model.actions.editing?.rootPathPicker == nil)
        #expect(model.makeFileBrowserStore(root: .project(id: "p-1")) == nil)
    }

    @Test func withFilesV1ThePickerOffersTheProjectRootsAndMintsProjectRootedStores() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [
            SupermuxProjectDTO(id: "p-1", name: "Alpha", rootPath: "/Users/dev/alpha"),
            SupermuxProjectDTO(id: "p-2", name: "Beta", rootPath: "/Users/dev/beta"),
        ])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [
                    SupermuxMobileCapability.projectsV1.rawValue,
                    SupermuxMobileCapability.filesV1.rawValue,
                ]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        let picker = try #require(model.actions.editing?.rootPathPicker)
        let options = picker.rootOptions()
        #expect(options.map(\.projectID) == ["p-1", "p-2"])
        #expect(options.map(\.rootPath) == ["/Users/dev/alpha", "/Users/dev/beta"])

        let store = try #require(picker.makeBrowserStore("p-2"))
        #expect(store.root == .project(id: "p-2"))
        #expect(store.showsFileBrowser)
    }

    @Test func endedSessionsStopMintingBrowserStores() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [
                    SupermuxMobileCapability.projectsV1.rawValue,
                    SupermuxMobileCapability.filesV1.rawValue,
                ]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.isVisible }

        model.endSession()
        #expect(model.makeFileBrowserStore(root: .workspace(id: "w-1")) == nil)
        #expect(model.actions.editing?.rootPathPicker == nil)
    }
}

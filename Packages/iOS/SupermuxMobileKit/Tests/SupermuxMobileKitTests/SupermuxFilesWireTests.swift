import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// The `mobile.supermux.files.*` wire shapes: each typed request maps to the
/// exact §2 method string and params the Mac handlers expect (root selector
/// `workspace_id` XOR `project_id`, root-relative paths), and the result
/// envelopes decode tolerantly (unknown fields ignored, all fields optional).
@Suite struct SupermuxFilesWireTests {
    private static let workspaceID = "7B1D4C22-9F3A-4E0D-B7A1-5C6E8F0A2D33"
    private static let projectID = "11111111-1111-1111-1111-111111111111"

    private static let workspaceRoot = SupermuxFilesRoot.workspace(id: workspaceID)
    private static let projectRoot = SupermuxFilesRoot.project(id: projectID)

    // MARK: Requests

    @Test func listAtTheRootOmitsThePathKey() {
        let request = SupermuxFilesListRequest(root: Self.workspaceRoot, path: nil)
        #expect(request.wireMethod == "mobile.supermux.files.list")
        #expect(request.wireParams as NSDictionary == ["workspace_id": Self.workspaceID])
    }

    @Test func listTreatsAnEmptyPathAsTheRoot() {
        let request = SupermuxFilesListRequest(root: Self.workspaceRoot, path: "")
        #expect(request.wireParams as NSDictionary == ["workspace_id": Self.workspaceID])
    }

    @Test func listOfANestedDirectoryCarriesTheRootRelativePath() {
        let request = SupermuxFilesListRequest(root: Self.projectRoot, path: "src/nested")
        #expect(request.wireMethod == "mobile.supermux.files.list")
        #expect(request.wireParams as NSDictionary == [
            "project_id": Self.projectID,
            "path": "src/nested",
        ])
    }

    @Test func createFileWireShape() {
        let request = SupermuxFilesCreateRequest(
            root: Self.workspaceRoot,
            path: "src/new.swift",
            kind: .file
        )
        #expect(request.wireMethod == "mobile.supermux.files.create")
        #expect(request.wireParams as NSDictionary == [
            "workspace_id": Self.workspaceID,
            "path": "src/new.swift",
            "kind": "file",
        ])
    }

    @Test func createFolderWireShape() {
        let request = SupermuxFilesCreateRequest(
            root: Self.projectRoot,
            path: "Docs",
            kind: .folder
        )
        #expect(request.wireParams as NSDictionary == [
            "project_id": Self.projectID,
            "path": "Docs",
            "kind": "folder",
        ])
    }

    @Test func renameWireShape() {
        let request = SupermuxFilesRenameRequest(
            root: Self.workspaceRoot,
            path: "src/main.swift",
            newName: "renamed.swift"
        )
        #expect(request.wireMethod == "mobile.supermux.files.rename")
        #expect(request.wireParams as NSDictionary == [
            "workspace_id": Self.workspaceID,
            "path": "src/main.swift",
            "new_name": "renamed.swift",
        ])
    }

    @Test func duplicateWireShape() {
        let request = SupermuxFilesDuplicateRequest(root: Self.workspaceRoot, path: "notes.md")
        #expect(request.wireMethod == "mobile.supermux.files.duplicate")
        #expect(request.wireParams as NSDictionary == [
            "workspace_id": Self.workspaceID,
            "path": "notes.md",
        ])
    }

    @Test func trashWireShape() {
        let request = SupermuxFilesTrashRequest(
            root: Self.workspaceRoot,
            paths: ["src/main.swift", "notes.md"]
        )
        #expect(request.wireMethod == "mobile.supermux.files.trash")
        #expect(request.wireParams as NSDictionary == [
            "workspace_id": Self.workspaceID,
            "paths": ["src/main.swift", "notes.md"],
        ])
    }

    // MARK: Responses

    @Test func listResponseDecodesEntriesAndToleratesUnknownFields() throws {
        let json = Data("""
        {
            "path": "src",
            "entries": [
                {"name": "nested", "is_dir": true, "is_symlink": false, "future_field": 1},
                {"name": "main.swift", "is_dir": false, "is_symlink": false, "size": 42,
                 "modified_at": 1783000000.5}
            ],
            "future_top_level": {"x": true}
        }
        """.utf8)
        let response = try JSONDecoder().decode(SupermuxFilesListResponse.self, from: json)
        #expect(response.path == "src")
        #expect(response.entries?.map(\.name) == ["nested", "main.swift"])
        #expect(response.entries?.first?.isDir == true)
        #expect(response.entries?.last?.size == 42)
    }

    @Test func mutationResponseDecodesOkAndOptionalPath() throws {
        let withPath = try JSONDecoder().decode(
            SupermuxFilesMutationResponse.self,
            from: Data(#"{"ok": true, "path": "src/new.swift", "extra": []}"#.utf8)
        )
        #expect(withPath.ok == true)
        #expect(withPath.path == "src/new.swift")

        let trashShape = try JSONDecoder().decode(
            SupermuxFilesMutationResponse.self,
            from: Data(#"{"ok": true}"#.utf8)
        )
        #expect(trashShape.ok == true)
        #expect(trashShape.path == nil)
    }

    // MARK: Name validation

    @Test func fileNameValidationFlagsEmptySlashAndReservedNames() {
        #expect(SupermuxFileName.issue(with: "readme.md") == nil)
        #expect(SupermuxFileName.issue(with: "  spaced name  ") == nil)
        #expect(SupermuxFileName.issue(with: "") == .empty)
        #expect(SupermuxFileName.issue(with: "   ") == .empty)
        #expect(SupermuxFileName.issue(with: "a/b") == .containsSlash)
        #expect(SupermuxFileName.issue(with: ".") == .reserved)
        #expect(SupermuxFileName.issue(with: "..") == .reserved)
    }

    @Test func fileNameNormalizationTrimsWhitespace() {
        #expect(SupermuxFileName.normalized("  notes.md \n") == "notes.md")
    }
}

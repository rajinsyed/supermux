import Foundation
import Testing

@testable import SupermuxKit

@Suite struct SupermuxFileSystemOperationsTests {
    /// Creates a fresh empty temporary directory for one test and removes it after.
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-fileops-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    // MARK: - Name validation

    @Test func validatedNameTrimsWhitespace() throws {
        #expect(try SupermuxFileSystemOperations.validatedName("  notes.txt  ") == "notes.txt")
    }

    @Test func validatedNameRejectsEmptyAndSeparators() {
        for bad in ["", "   ", "a/b", ".", "..", "x\u{0}y"] {
            #expect(throws: SupermuxFileSystemOperationError.self) {
                try SupermuxFileSystemOperations.validatedName(bad)
            }
        }
    }

    // MARK: - Create file

    @Test func createFileMakesEmptyFile() throws {
        try withTemporaryDirectory { root in
            let url = try SupermuxFileSystemOperations.createFile(named: "hello.swift", in: root)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(url.lastPathComponent == "hello.swift")
        }
    }

    @Test func createFileThrowsWhenNameExists() throws {
        try withTemporaryDirectory { root in
            _ = try SupermuxFileSystemOperations.createFile(named: "dup.txt", in: root)
            #expect(throws: SupermuxFileSystemOperationError.alreadyExists(name: "dup.txt")) {
                try SupermuxFileSystemOperations.createFile(named: "dup.txt", in: root)
            }
        }
    }

    @Test func createFileThrowsOnInvalidName() throws {
        try withTemporaryDirectory { root in
            #expect(throws: SupermuxFileSystemOperationError.invalidName("bad/name")) {
                try SupermuxFileSystemOperations.createFile(named: "bad/name", in: root)
            }
        }
    }

    // MARK: - Create directory

    @Test func createDirectoryMakesDirectory() throws {
        try withTemporaryDirectory { root in
            let url = try SupermuxFileSystemOperations.createDirectory(named: "src", in: root)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    @Test func createDirectoryThrowsWhenNameExists() throws {
        try withTemporaryDirectory { root in
            _ = try SupermuxFileSystemOperations.createDirectory(named: "src", in: root)
            #expect(throws: SupermuxFileSystemOperationError.alreadyExists(name: "src")) {
                try SupermuxFileSystemOperations.createDirectory(named: "src", in: root)
            }
        }
    }

    // MARK: - Rename

    @Test func renameMovesItemToNewName() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "old.txt", in: root)
            let renamed = try SupermuxFileSystemOperations.rename(original, to: "new.txt")
            #expect(renamed.lastPathComponent == "new.txt")
            #expect(FileManager.default.fileExists(atPath: renamed.path))
            #expect(!FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test func renameToSameNameIsNoOp() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "keep.txt", in: root)
            let result = try SupermuxFileSystemOperations.rename(original, to: "keep.txt")
            #expect(result.standardizedFileURL == original.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: result.path))
        }
    }

    @Test func renameThrowsOnCollision() throws {
        try withTemporaryDirectory { root in
            let a = try SupermuxFileSystemOperations.createFile(named: "a.txt", in: root)
            _ = try SupermuxFileSystemOperations.createFile(named: "b.txt", in: root)
            #expect(throws: SupermuxFileSystemOperationError.alreadyExists(name: "b.txt")) {
                try SupermuxFileSystemOperations.rename(a, to: "b.txt")
            }
        }
    }

    @Test func renameThrowsOnInvalidName() throws {
        try withTemporaryDirectory { root in
            let a = try SupermuxFileSystemOperations.createFile(named: "a.txt", in: root)
            #expect(throws: SupermuxFileSystemOperationError.invalidName("a/b")) {
                try SupermuxFileSystemOperations.rename(a, to: "a/b")
            }
        }
    }

    // MARK: - Duplicate

    @Test func duplicateCreatesCopyWithSuffix() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "report.md", in: root)
            let copy = try SupermuxFileSystemOperations.duplicate(original)
            #expect(copy.lastPathComponent == "report copy.md")
            #expect(FileManager.default.fileExists(atPath: copy.path))
            #expect(FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test func duplicateIncrementsWhenCopyExists() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "report.md", in: root)
            _ = try SupermuxFileSystemOperations.duplicate(original)
            let second = try SupermuxFileSystemOperations.duplicate(original)
            #expect(second.lastPathComponent == "report copy 2.md")
        }
    }

    @Test func duplicateExtensionlessFile() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "Makefile", in: root)
            let copy = try SupermuxFileSystemOperations.duplicate(original)
            #expect(copy.lastPathComponent == "Makefile copy")
        }
    }

    @Test func duplicateOfExistingCopyContinuesSequence() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "report.md", in: root)
            let firstCopy = try SupermuxFileSystemOperations.duplicate(original)
            // Duplicating the copy itself should yield "report copy 2.md" (Finder
            // parity), not "report copy copy.md".
            let second = try SupermuxFileSystemOperations.duplicate(firstCopy)
            #expect(second.lastPathComponent == "report copy 2.md")
        }
    }

    @Test func duplicatePreservesOnlyTheLastExtension() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "archive.tar.gz", in: root)
            let copy = try SupermuxFileSystemOperations.duplicate(original)
            #expect(copy.lastPathComponent == "archive.tar copy.gz")
        }
    }

    @Test func duplicateDotfileTreatsWholeNameAsBase() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: ".env", in: root)
            let copy = try SupermuxFileSystemOperations.duplicate(original)
            #expect(copy.lastPathComponent == ".env copy")
        }
    }

    @Test func duplicateDottedDirectoryKeepsFullName() throws {
        try withTemporaryDirectory { root in
            let dir = try SupermuxFileSystemOperations.createDirectory(named: "my.config", in: root)
            let copy = try SupermuxFileSystemOperations.duplicate(dir)
            // A dotted folder name is a whole base, not name + extension.
            #expect(copy.lastPathComponent == "my.config copy")
        }
    }

    @Test func duplicateFolderCopiesChildrenRecursively() throws {
        try withTemporaryDirectory { root in
            let dir = try SupermuxFileSystemOperations.createDirectory(named: "src", in: root)
            _ = try SupermuxFileSystemOperations.createFile(named: "a.txt", in: dir)
            let copy = try SupermuxFileSystemOperations.duplicate(dir)
            #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("a.txt").path))
        }
    }

    // MARK: - Case-only rename

    @Test func renameCaseOnlySucceeds() throws {
        try withTemporaryDirectory { root in
            let original = try SupermuxFileSystemOperations.createFile(named: "Readme.md", in: root)
            let renamed = try SupermuxFileSystemOperations.rename(original, to: "README.md")
            #expect(renamed.lastPathComponent == "README.md")
            #expect(FileManager.default.fileExists(atPath: renamed.path))
        }
    }

    // MARK: - Trash (best-effort, idempotent)

    @Test func moveToTrashRemovesItemFromDirectory() throws {
        try withTemporaryDirectory { root in
            let file = try SupermuxFileSystemOperations.createFile(named: "trashme.txt", in: root)
            try SupermuxFileSystemOperations.moveToTrash([file])
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func moveToTrashSkipsMissingItems() throws {
        try withTemporaryDirectory { root in
            // A missing item is treated as already-removed: no throw, idempotent.
            let ghost = root.appendingPathComponent("ghost.txt")
            try SupermuxFileSystemOperations.moveToTrash([ghost])
        }
    }

    @Test func moveToTrashTrashesPresentAndSkipsMissingInOneBatch() throws {
        try withTemporaryDirectory { root in
            let present = try SupermuxFileSystemOperations.createFile(named: "present.txt", in: root)
            let ghost = root.appendingPathComponent("ghost.txt")
            // Mixed batch: the present item is trashed, the missing one skipped,
            // and the call does not throw (the partial-failure path Codex flagged).
            try SupermuxFileSystemOperations.moveToTrash([present, ghost])
            #expect(!FileManager.default.fileExists(atPath: present.path))
        }
    }

    // MARK: - Nested-selection de-dup (topLevelPaths)

    @Test func topLevelPathsDropsDescendantsOfSelectedAncestor() {
        let result = SupermuxFileSystemOperations.topLevelPaths(["/a", "/a/b", "/a/b/c"])
        #expect(result == ["/a"])
    }

    @Test func topLevelPathsKeepsSiblings() {
        let result = SupermuxFileSystemOperations.topLevelPaths(["/a/x", "/a/y"])
        #expect(result == ["/a/x", "/a/y"])
    }

    @Test func topLevelPathsDoesNotTreatPrefixSiblingAsAncestor() {
        // "/foo" must NOT be considered an ancestor of "/foobar".
        let result = SupermuxFileSystemOperations.topLevelPaths(["/foo", "/foobar"])
        #expect(result == ["/foo", "/foobar"])
    }

    @Test func topLevelPathsTreatsRootAsAncestorOfEverything() {
        let result = SupermuxFileSystemOperations.topLevelPaths(["/", "/a", "/b"])
        #expect(result == ["/"])
    }

    @Test func pathIsAncestorEdgeCases() {
        #expect(SupermuxFileSystemOperations.pathIsAncestor("/a", of: "/a/b"))
        #expect(!SupermuxFileSystemOperations.pathIsAncestor("/a", of: "/a"))
        #expect(!SupermuxFileSystemOperations.pathIsAncestor("/foo", of: "/foobar"))
        #expect(SupermuxFileSystemOperations.pathIsAncestor("/", of: "/anything"))
    }
}

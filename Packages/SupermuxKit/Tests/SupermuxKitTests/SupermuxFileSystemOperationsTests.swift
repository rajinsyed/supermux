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
            var isDir: ObjCBool = true
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
            #expect(!isDir.boolValue)                      // a regular file, not a directory
            #expect(url.lastPathComponent == "hello.swift")
            #expect(try Data(contentsOf: url).isEmpty)     // and it is empty
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
            // Probe volume case-sensitivity deterministically so the assertions
            // are explicit about which branch ran.
            let probe = root.appendingPathComponent("CaseProbe")
            try Data().write(to: probe)
            let caseInsensitive = FileManager.default.fileExists(
                atPath: root.appendingPathComponent("caseprobe").path)
            try FileManager.default.removeItem(at: probe)

            let original = try SupermuxFileSystemOperations.createFile(named: "Readme.md", in: root)
            let renamed = try SupermuxFileSystemOperations.rename(original, to: "README.md")
            #expect(renamed.lastPathComponent == "README.md")
            #expect(FileManager.default.fileExists(atPath: renamed.path))
            if caseInsensitive {
                // Case-only rename went through the sameOnDiskItem branch: the
                // single underlying file was renamed in place (no duplicate item).
                let matches = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .filter { $0.lowercased() == "readme.md" }
                #expect(matches == ["README.md"])
            } else {
                // Case-sensitive volume: this was a plain move, so the old name
                // must be gone (a copy-instead-of-move regression would fail here).
                // NOTE: this assertion is only valid here — on a case-insensitive
                // volume "Readme.md" still resolves to the renamed file.
                #expect(!FileManager.default.fileExists(atPath: original.path))
            }
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
            // Mixed batch: the present item is trashed and the missing one is
            // skipped (not an error), so the call does not throw.
            try SupermuxFileSystemOperations.moveToTrash([present, ghost])
            #expect(!FileManager.default.fileExists(atPath: present.path))
        }
    }

    @Test func moveToTrashAttemptsWholeBatchAndAggregatesFailures() throws {
        try withTemporaryDirectory { root in
            let bad1 = try SupermuxFileSystemOperations.createFile(named: "bad1.txt", in: root)
            let good = try SupermuxFileSystemOperations.createFile(named: "good.txt", in: root)
            let bad2 = try SupermuxFileSystemOperations.createFile(named: "bad2.txt", in: root)
            // TWO failing items with a good one between: proves the loop continues
            // past a mid-batch failure AND that BOTH failures are aggregated into a
            // single .failed(reason:) (exercises the failures.joined branch).
            let fm = FailingTrashFileManager(failingFor: [bad1, bad2])
            var thrown: (any Error)?
            #expect(throws: SupermuxFileSystemOperationError.self) {
                do {
                    try SupermuxFileSystemOperations.moveToTrash([bad1, good, bad2], fileManager: fm)
                } catch {
                    thrown = error
                    throw error
                }
            }
            #expect(FileManager.default.fileExists(atPath: bad1.path))    // both bads remain
            #expect(FileManager.default.fileExists(atPath: bad2.path))
            #expect(!FileManager.default.fileExists(atPath: good.path))   // good trashed despite both failures
            if case let .failed(reason)? = thrown as? SupermuxFileSystemOperationError {
                #expect(reason.contains("bad1.txt"))
                #expect(reason.contains("bad2.txt"))
            } else {
                Issue.record("expected aggregate .failed naming both items, got \(String(describing: thrown))")
            }
        }
    }

    @Test func moveToTrashUsesTrashItemNotDelete() throws {
        try withTemporaryDirectory { root in
            let file = try SupermuxFileSystemOperations.createFile(named: "recoverable.txt", in: root)
            // Proves the recoverable-Trash contract behind the "Move to Trash" /
            // "restore later from the Trash" UI copy: trashItem is invoked (not removeItem).
            let fm = RecordingTrashFileManager()
            try SupermuxFileSystemOperations.moveToTrash([file], fileManager: fm)
            #expect(fm.trashedPaths == [file.standardizedFileURL.path])
            #expect(!FileManager.default.fileExists(atPath: file.path))
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

    // MARK: - Duplicate copies real content

    @Test func duplicateCopiesFileContents() throws {
        try withTemporaryDirectory { root in
            let original = root.appendingPathComponent("note.txt")
            try "hello world".write(to: original, atomically: true, encoding: .utf8)
            let copy = try SupermuxFileSystemOperations.duplicate(original)
            #expect(try String(contentsOf: copy, encoding: .utf8) == "hello world")
        }
    }

    @Test func duplicateFolderCopiesChildContents() throws {
        try withTemporaryDirectory { root in
            let dir = try SupermuxFileSystemOperations.createDirectory(named: "src", in: root)
            try "fn main() {}".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
            let copy = try SupermuxFileSystemOperations.duplicate(dir)
            let copiedChild = copy.appendingPathComponent("main.swift")
            #expect(try String(contentsOf: copiedChild, encoding: .utf8) == "fn main() {}")
        }
    }

    // MARK: - .notFound on a vanished source

    @Test func renameThrowsNotFoundWhenSourceMissing() throws {
        try withTemporaryDirectory { root in
            let ghost = root.appendingPathComponent("ghost.txt")
            #expect(throws: SupermuxFileSystemOperationError.notFound(path: ghost.path)) {
                try SupermuxFileSystemOperations.rename(ghost, to: "new.txt")
            }
        }
    }

    @Test func duplicateThrowsNotFoundWhenSourceMissing() throws {
        try withTemporaryDirectory { root in
            let ghost = root.appendingPathComponent("ghost.txt")
            #expect(throws: SupermuxFileSystemOperationError.notFound(path: ghost.path)) {
                try SupermuxFileSystemOperations.duplicate(ghost)
            }
        }
    }

    // MARK: - Copy-stem lowest-free-slot policy

    @Test func duplicateOfNumberedCopyFillsLowestFreeSlot() throws {
        try withTemporaryDirectory { root in
            // Only "x copy 3.txt" exists; duplicating it reuses the " copy" stem and
            // fills the lowest free slot → "x copy.txt".
            let numbered = try SupermuxFileSystemOperations.createFile(named: "x copy 3.txt", in: root)
            let copy = try SupermuxFileSystemOperations.duplicate(numbered)
            #expect(copy.lastPathComponent == "x copy.txt")
        }
    }

    @Test func duplicateWalksToNextFreeSlotWhenLowerExist() throws {
        try withTemporaryDirectory { root in
            _ = try SupermuxFileSystemOperations.createFile(named: "x copy.txt", in: root)
            _ = try SupermuxFileSystemOperations.createFile(named: "x copy 2.txt", in: root)
            let numbered = try SupermuxFileSystemOperations.createFile(named: "x copy 3.txt", in: root)
            // stem "x", slots " copy"/" copy 2"/" copy 3" taken → next free is " copy 4".
            let copy = try SupermuxFileSystemOperations.duplicate(numbered)
            #expect(copy.lastPathComponent == "x copy 4.txt")
        }
    }

    // MARK: - createDirectory invalid-name propagation

    @Test func createDirectoryThrowsOnInvalidName() throws {
        try withTemporaryDirectory { root in
            #expect(throws: SupermuxFileSystemOperationError.invalidName("bad/name")) {
                try SupermuxFileSystemOperations.createDirectory(named: "bad/name", in: root)
            }
        }
    }
}

/// A `FileManager` that fails to trash exactly one URL (delegating everything
/// else to the real implementation), so the aggregate-failure path of
/// `moveToTrash` can be exercised deterministically.
private final class FailingTrashFileManager: FileManager, @unchecked Sendable {
    private let failingPaths: Set<String>
    init(failingFor urls: [URL]) {
        self.failingPaths = Set(urls.map { $0.standardizedFileURL.path })
        super.init()
    }
    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        if failingPaths.contains(url.standardizedFileURL.path) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.trashItem(at: url, resultingItemURL: outResultingURL)
    }
}

/// A `FileManager` that records which URLs `trashItem` was asked to move (and
/// performs the real move), proving the operation uses the recoverable Trash.
private final class RecordingTrashFileManager: FileManager, @unchecked Sendable {
    private(set) var trashedPaths: [String] = []
    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        trashedPaths.append(url.standardizedFileURL.path)
        try super.trashItem(at: url, resultingItemURL: outResultingURL)
    }
}

import Foundation
import SupermuxMobileCore
import Testing

@testable import SupermuxKit

/// Coverage for the `mobile.supermux.files.*` engine (architecture §10;
/// validation contract RPC-FILE-01/02/03): fixture-tree listing, on-disk
/// verified operations, and root confinement (`..` traversal + symlink
/// escape rejected with no filesystem effect outside the root).
@Suite struct SupermuxMobileFileBrowserTests {
    /// Runs `body` with a fresh temporary base directory (removed after).
    /// The browser root is a SUBDIRECTORY of the base so escape tests can
    /// verify nothing leaked into the area just outside the root.
    private func withBase(_ body: (URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-filebrowser-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    /// Builds the RPC-FILE-01 fixture tree inside `base/root` and returns it:
    ///
    ///     root/
    ///       README.md          ("hello", 5 bytes)
    ///       link.md    -> README.md
    ///       linkdir    -> docs
    ///       .hidden            (dotfile, must not list)
    ///       docs/guide.md
    ///       src/main.swift
    ///       src/nested/deep.txt
    private func makeFixtureRoot(in base: URL) throws -> URL {
        let fm = FileManager.default
        let root = base.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("src/nested"), withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("docs/guide.md"))
        try Data().write(to: root.appendingPathComponent("src/main.swift"))
        try Data().write(to: root.appendingPathComponent("src/nested/deep.txt"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("link.md"),
            withDestinationURL: root.appendingPathComponent("README.md")
        )
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("linkdir"),
            withDestinationURL: root.appendingPathComponent("docs")
        )
        return root
    }

    /// An escape fixture: `base/outside/secret.txt` lives OUTSIDE the root,
    /// and `root/escape` is a symlink pointing at that outside directory.
    private func makeEscapeFixture(in base: URL) throws -> (root: URL, outside: URL) {
        let fm = FileManager.default
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        return (root, outside)
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: - RPC-FILE-01: fixture tree listing

    @Test func listRootReturnsFixtureChildrenDirsFirstCaseInsensitive() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let entries = try browser.list(path: nil)
            // Desktop file-explorer order: directories first (symlink-to-dir
            // counts as a directory), then case-insensitive by name.
            #expect(entries.map(\.name) == ["docs", "linkdir", "src", "link.md", "README.md"])

            let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
            #expect(byName["docs"]?.isDir == true)
            #expect(byName["docs"]?.isSymlink == false)
            #expect(byName["linkdir"]?.isDir == true)
            #expect(byName["linkdir"]?.isSymlink == true)
            #expect(byName["src"]?.isDir == true)
            #expect(byName["link.md"]?.isDir == false)
            #expect(byName["link.md"]?.isSymlink == true)
            #expect(byName["README.md"]?.isDir == false)
            #expect(byName["README.md"]?.isSymlink == false)
            #expect(byName["README.md"]?.size == 5)
            #expect(byName["README.md"]?.modifiedAt != nil)
        }
    }

    @Test func listExcludesDotfilesMirroringDesktopDefault() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let names = try browser.list(path: nil).map(\.name)
            #expect(!names.contains(".hidden"))
        }
    }

    @Test func listResolvesNestedPathsRelativeToTheRoot() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(try browser.list(path: "src").map(\.name) == ["nested", "main.swift"])
            #expect(try browser.list(path: "src/nested").map(\.name) == ["deep.txt"])
            #expect(try browser.list(path: "./src/").map(\.name) == ["nested", "main.swift"])
        }
    }

    @Test func listPayloadCarriesSnakeCaseEntriesAndEchoesThePath() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let payload = try browser.listPayload(path: "src")
            #expect(payload["path"] as? String == "src")
            let entries = try #require(payload["entries"] as? [[String: Any]])
            #expect(entries.first?["name"] as? String == "nested")
            #expect(entries.first?["is_dir"] as? Bool == true)
            #expect(entries.first?["is_symlink"] as? Bool == false)

            let rootPayload = try browser.listPayload(path: nil)
            #expect(rootPayload["path"] as? String == "")
        }
    }

    @Test func listRejectsFilesAndMissingPaths() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(throws: SupermuxMobileFileBrowserError.invalidPath(path: "README.md")) {
                try browser.list(path: "README.md")
            }
            #expect(throws: SupermuxMobileFileBrowserError.notFound(path: "nope")) {
                try browser.list(path: "nope")
            }
        }
    }

    @Test func initCanonicalizesASymlinkedRootAndRejectsMissingRoots() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let rootLink = base.appendingPathComponent("rootlink")
            try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
            let browser = try SupermuxMobileFileBrowser(rootPath: rootLink.path)
            #expect(browser.rootPath == root.resolvingSymlinksInPath().path)
            #expect(try browser.list(path: "src").map(\.name) == ["nested", "main.swift"])

            let missing = base.appendingPathComponent("does-not-exist").path
            #expect(throws: SupermuxMobileFileBrowserError.rootUnavailable(path: missing)) {
                _ = try SupermuxMobileFileBrowser(rootPath: missing)
            }
        }
    }

    // MARK: - RPC-FILE-02: operations with on-disk verification

    @Test func createFileWritesAnEmptyFileAndReturnsItsRelativePath() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let relative = try browser.createFile(at: "src/new.txt")
            #expect(relative == "src/new.txt")
            let url = root.appendingPathComponent("src/new.txt")
            var isDir: ObjCBool = true
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
            #expect(!isDir.boolValue)
            #expect(try Data(contentsOf: url).isEmpty)
        }
    }

    @Test func createFolderCreatesADirectory() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let relative = try browser.createFolder(at: "docs/assets")
            #expect(relative == "docs/assets")
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("docs/assets").path, isDirectory: &isDir
            ))
            #expect(isDir.boolValue)
        }
    }

    @Test func renameMovesTheEntryOnDisk() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let relative = try browser.rename(path: "README.md", to: "INTRO.md")
            #expect(relative == "INTRO.md")
            #expect(!exists(root.appendingPathComponent("README.md")))
            let renamed = root.appendingPathComponent("INTRO.md")
            #expect(try String(decoding: Data(contentsOf: renamed), as: UTF8.self) == "hello")
        }
    }

    @Test func duplicateCreatesAFinderStyleCopySibling() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let relative = try browser.duplicate(path: "README.md")
            #expect(relative == "README copy.md")
            let copy = root.appendingPathComponent("README copy.md")
            #expect(try String(decoding: Data(contentsOf: copy), as: UTF8.self) == "hello")
            #expect(exists(root.appendingPathComponent("README.md")))
        }
    }

    @Test func trashRemovesEntriesFromTheirPathsViaTheTrash() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            // Batch: a file and a whole directory; both must leave their paths
            // (moveToTrash uses FileManager.trashItem, never removeItem).
            try browser.trash(paths: ["src/main.swift", "docs"])
            #expect(!exists(root.appendingPathComponent("src/main.swift")))
            #expect(!exists(root.appendingPathComponent("docs")))
            #expect(exists(root.appendingPathComponent("src")))
        }
    }

    @Test func requestPathsPreserveLeadingAndTrailingWhitespace() throws {
        // Regression: a name with edge whitespace must resolve to that exact
        // entry, never a trimmed neighbor. With both " report.txt" (leading
        // space) and "report.txt" present, trashing " report.txt" must remove
        // the spaced file and leave the unspaced one — trimming the request
        // path here would trash the wrong file (data loss).
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let spaced = root.appendingPathComponent(" report.txt")
            let plain = root.appendingPathComponent("report.txt")
            try Data("spaced".utf8).write(to: spaced)
            try Data("plain".utf8).write(to: plain)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)

            try browser.trash(paths: [" report.txt"])

            #expect(!exists(spaced))
            #expect(exists(plain))
            #expect(try String(decoding: Data(contentsOf: plain), as: UTF8.self) == "plain")
        }
    }

    @Test func trashSkipsAlreadyMissingEntries() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            try browser.trash(paths: ["already-gone.txt", "README.md"])
            #expect(!exists(root.appendingPathComponent("README.md")))
        }
    }

    @Test func operationSequenceCreateRenameDuplicateTrash() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            _ = try browser.createFile(at: "notes.txt")
            #expect(exists(root.appendingPathComponent("notes.txt")))
            let renamed = try browser.rename(path: "notes.txt", to: "journal.txt")
            #expect(renamed == "journal.txt")
            let copy = try browser.duplicate(path: "journal.txt")
            #expect(copy == "journal copy.txt")
            try browser.trash(paths: ["journal.txt", "journal copy.txt"])
            #expect(!exists(root.appendingPathComponent("journal.txt")))
            #expect(!exists(root.appendingPathComponent("journal copy.txt")))
        }
    }

    // MARK: - RPC-FILE-03: `..` traversal and symlink escape rejected, no effect

    @Test func dotDotTraversalIsRejectedByEveryMethodWithNoEffect() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            try Data("victim".utf8).write(to: base.appendingPathComponent("victim.txt"))
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)

            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.list(path: "..")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.createFile(at: "../evil.txt")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.createFolder(at: "src/../../evil-folder")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.rename(path: "../victim.txt", to: "renamed.txt")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.duplicate(path: "../victim.txt")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.trash(paths: ["../victim.txt"])
            }

            // No filesystem effect outside the root.
            #expect(!exists(base.appendingPathComponent("evil.txt")))
            #expect(!exists(base.appendingPathComponent("evil-folder")))
            #expect(exists(base.appendingPathComponent("victim.txt")))
            #expect(!exists(base.appendingPathComponent("renamed.txt")))
            #expect(!exists(base.appendingPathComponent("victim copy.txt")))
        }
    }

    @Test func symlinkEscapeIsRejectedByEveryMethodWithNoEffect() throws {
        try withBase { base in
            let (root, outside) = try makeEscapeFixture(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)

            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.list(path: "escape")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.createFile(at: "escape/evil.txt")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.rename(path: "escape/secret.txt", to: "renamed.txt")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.duplicate(path: "escape/secret.txt")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.trash(paths: ["escape/secret.txt"])
            }
            // The escaping symlink entry itself resolves outside → rejected too.
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.trash(paths: ["escape"])
            }

            // The outside directory is untouched: exactly its original file.
            let outsideNames = try FileManager.default.contentsOfDirectory(atPath: outside.path)
            #expect(outsideNames == ["secret.txt"])
            #expect(try String(
                decoding: Data(contentsOf: outside.appendingPathComponent("secret.txt")),
                as: UTF8.self
            ) == "secret")
        }
    }

    @Test func trashBatchWithOneEscapingPathHasNoEffectAtAll() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            try Data("victim".utf8).write(to: base.appendingPathComponent("victim.txt"))
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.trash(paths: ["README.md", "../victim.txt"])
            }
            // Validation is batch-first: the confined entry survives too.
            #expect(exists(root.appendingPathComponent("README.md")))
            #expect(exists(base.appendingPathComponent("victim.txt")))
        }
    }

    @Test func mutatingTheRootItselfIsRejected() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.trash(paths: [""])
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.rename(path: ".", to: "x")
            }
            #expect(throws: SupermuxMobileFileBrowserError.self) {
                try browser.duplicate(path: "")
            }
            #expect(exists(root))
        }
    }

    @Test func renameRejectsNamesThatAreNotASingleComponent() throws {
        try withBase { base in
            let root = try makeFixtureRoot(in: base)
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(throws: SupermuxFileSystemOperationError.invalidName("../x")) {
                try browser.rename(path: "README.md", to: "../x")
            }
            #expect(throws: SupermuxFileSystemOperationError.invalidName("a/b")) {
                try browser.rename(path: "README.md", to: "a/b")
            }
            #expect(exists(root.appendingPathComponent("README.md")))
        }
    }

    // MARK: - Wire error classification

    @Test func wireClassificationMapsConfinementAndNamingToInvalidParams() {
        func code(_ error: any Error) -> String {
            SupermuxMobileFilesWireFailure.classify(error).code
        }
        #expect(code(SupermuxMobileFileBrowserError.pathOutsideRoot(path: "x")) == "invalid_params")
        #expect(code(SupermuxMobileFileBrowserError.invalidPath(path: "x")) == "invalid_params")
        #expect(code(SupermuxMobileFileBrowserError.notFound(path: "x")) == "not_found")
        #expect(code(SupermuxMobileFileBrowserError.rootUnavailable(path: "x")) == "unavailable")
        #expect(code(SupermuxFileSystemOperationError.invalidName("..")) == "invalid_params")
        #expect(code(SupermuxFileSystemOperationError.alreadyExists(name: "x")) == "invalid_params")
        #expect(code(SupermuxFileSystemOperationError.notFound(path: "x")) == "not_found")
        #expect(code(SupermuxFileSystemOperationError.failed(reason: "io")) == "unavailable")
        #expect(code(CocoaError(.fileWriteUnknown)) == "unavailable")
    }
}

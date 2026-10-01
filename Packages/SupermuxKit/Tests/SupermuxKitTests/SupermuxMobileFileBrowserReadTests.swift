import Foundation
import SupermuxMobileCore
import Testing

@testable import SupermuxKit

/// Failure modes of the read-only `files.*` surface another Mac's Files panel
/// uses (`files.list {show_hidden}` and `files.read`), written before the
/// engine code:
/// - a `..` path or a symlink out of the root must never be read or listed;
/// - a directory, the root, a missing entry or an out-of-range offset is not a
///   read; a chunk never exceeds the host's cap however large the request;
/// - hidden files list exactly as the desktop panel lists them with hidden
///   files shown (`.git` included), while the phone's listing keeps hiding
///   dotfiles; git internals are readable but stay immutable.
@Suite struct SupermuxMobileFileBrowserReadTests {
    private func withRoot(_ body: (_ base: URL, _ root: URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-fileread-tests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try Data("0123456789".utf8).write(to: root.appendingPathComponent("digits.txt"))
        try Data("ref: refs/heads/main\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        try Data("KEY=1\n".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("secret".utf8).write(to: base.appendingPathComponent("outside/secret.txt"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: base.appendingPathComponent("outside")
        )
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("escape.txt"),
            withDestinationURL: base.appendingPathComponent("outside/secret.txt")
        )
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("alias.txt"), withDestinationURL: root.appendingPathComponent("digits.txt")
        )
        defer { try? fm.removeItem(at: base) }
        try body(base, root)
    }

    // MARK: - Confinement

    @Test func readRefusesEveryPathOutsideTheRoot() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            for path in ["../outside/secret.txt", "escape/secret.txt", "escape.txt", "src/../../outside/secret.txt"] {
                #expect(throws: SupermuxMobileFileBrowserError.pathOutsideRoot(path: path)) {
                    try browser.read(path: path, offset: 0, length: 10)
                }
            }
        }
    }

    @Test func hiddenListingRefusesASymlinkOutOfTheRoot() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(throws: SupermuxMobileFileBrowserError.pathOutsideRoot(path: "escape")) {
                try browser.list(path: "escape", showHidden: true)
            }
        }
    }

    // MARK: - Not a read

    @Test func readRefusesDirectoriesTheRootAndMissingEntries() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(throws: SupermuxMobileFileBrowserError.invalidPath(path: "src")) {
                try browser.read(path: "src", offset: 0, length: 10)
            }
            #expect(throws: SupermuxMobileFileBrowserError.invalidPath(path: "")) {
                try browser.read(path: "", offset: 0, length: 10)
            }
            #expect(throws: SupermuxMobileFileBrowserError.notFound(path: "missing.txt")) {
                try browser.read(path: "missing.txt", offset: 0, length: 10)
            }
        }
    }

    @Test func readRefusesOffsetsOutsideTheFile() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            #expect(throws: SupermuxMobileFileBrowserError.invalidPath(path: "digits.txt")) {
                try browser.read(path: "digits.txt", offset: -1, length: 10)
            }
            #expect(throws: SupermuxMobileFileBrowserError.invalidPath(path: "digits.txt")) {
                try browser.read(path: "digits.txt", offset: 11, length: 10)
            }
            let end = try browser.read(path: "digits.txt", offset: 10, length: 10)
            #expect(end.eof && end.length == 0 && end.data.isEmpty)
        }
    }

    /// A named pipe lists as a plain file, but opening it for reading waits
    /// for a writer. The read must refuse it at once: a host thread stuck in
    /// `open` would make the viewer miss its deadline and drop the link.
    @Test func readRefusesANamedPipeWithoutWaitingForAWriter() throws {
        try withRoot { _, root in
            let pipe = root.appendingPathComponent("pipe").path
            #expect(mkfifo(pipe, 0o600) == 0)
            // Releases a reader stuck in `open` (the bug), so the test ends.
            let release = Thread {
                Thread.sleep(forTimeInterval: 3)
                let writer = open(pipe, O_WRONLY | O_NONBLOCK)
                if writer >= 0 { close(writer) }
            }
            release.start()
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let started = Date()
            #expect(throws: SupermuxMobileFileBrowserError.invalidPath(path: "pipe")) {
                try browser.read(path: "pipe", offset: 0, length: 10)
            }
            #expect(Date().timeIntervalSince(started) < 2)
        }
    }

    // MARK: - Chunks

    @Test func readReturnsTheRequestedChunkAndSaysWhenItEnds() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let first = try browser.read(path: "digits.txt", offset: 0, length: 4)
            #expect(first.path == "digits.txt")
            #expect(first.size == 10 && first.offset == 0 && first.length == 4 && !first.eof)
            #expect(Data(base64Encoded: first.data) == Data("0123".utf8))
            #expect(first.modifiedAt > 0)
            let last = try browser.read(path: "digits.txt", offset: 4, length: 100)
            #expect(last.length == 6 && last.eof)
            #expect(Data(base64Encoded: last.data) == Data("456789".utf8))
        }
    }

    @Test func aChunkNeverExceedsTheCap() throws {
        try withRoot { _, root in
            let big = Data(repeating: 7, count: SupermuxMobileFileBrowser.maxReadChunk + 10)
            try big.write(to: root.appendingPathComponent("big.bin"))
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let chunk = try browser.read(path: "big.bin", offset: 0, length: Int.max)
            #expect(chunk.length == SupermuxMobileFileBrowser.maxReadChunk && !chunk.eof)
            let zero = try browser.read(path: "big.bin", offset: 0, length: 0)
            #expect(zero.length == SupermuxMobileFileBrowser.maxReadChunk)
        }
    }

    @Test func readFollowsASymlinkThatStaysInsideTheRoot() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let chunk = try browser.read(path: "alias.txt", offset: 0, length: 3)
            #expect(Data(base64Encoded: chunk.data) == Data("012".utf8))
        }
    }

    // MARK: - Hidden files and git internals

    @Test func hiddenListingMatchesTheDesktopPanelWithHiddenFilesShown() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let hidden = try browser.list(path: nil, showHidden: true).map(\.name)
            #expect(hidden.contains(".git") && hidden.contains(".env"))
            let phone = try browser.list(path: nil).map(\.name)
            #expect(!phone.contains { $0.hasPrefix(".") })
            #expect(try browser.list(path: ".git", showHidden: true).map(\.name) == ["HEAD"])
            #expect(throws: SupermuxMobileFileBrowserError.self) { try browser.list(path: ".git") }
        }
    }

    @Test func gitInternalsAreReadableButStayImmutable() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let head = try browser.read(path: ".git/HEAD", offset: 0, length: 100)
            #expect(Data(base64Encoded: head.data) == Data("ref: refs/heads/main\n".utf8))
            #expect(throws: SupermuxMobileFileBrowserError.self) { try browser.rename(path: ".git/HEAD", to: "x") }
            #expect(throws: SupermuxMobileFileBrowserError.self) { try browser.trash(paths: [".git"]) }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/HEAD").path))
        }
    }

    /// A huge folder must not produce a reply larger than the device link's
    /// frame: the listing stops at the cap and says so.
    @Test func hiddenListingStopsAtTheEntryCap() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let payload = try browser.listPayload(path: nil, showHidden: true, limit: 3)
            #expect((payload["entries"] as? [[String: Any]])?.count == 3)
            #expect(payload["truncated"] as? Bool == true)
            let whole = try browser.listPayload(path: nil, showHidden: true)
            #expect(whole["truncated"] == nil)
        }
    }

    @Test func listPayloadNamesTheHostHome() throws {
        try withRoot { _, root in
            let browser = try SupermuxMobileFileBrowser(rootPath: root.path)
            let payload = try browser.listPayload(path: nil, showHidden: true)
            #expect(payload["home"] as? String == NSHomeDirectory())
            let names = (payload["entries"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            #expect(names.contains(".git"))
        }
    }
}

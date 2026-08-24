import AppKit
import Darwin
import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessImageReaderTests {
    @Test func nestedImageUsesDetectedMimeTypeInsteadOfExtension() throws {
        let sandbox = try makeSandbox(named: "valid")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let imageURL = sandbox.root
            .appendingPathComponent("public/images", isDirectory: true)
            .appendingPathComponent("banner-v4.jpg")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.pngData.write(to: imageURL)

        let image = try sandbox.reader.read(
            relativePath: "public/images/banner-v4.jpg"
        )

        #expect(image.mediaType == "image/png")
        #expect(Data(base64Encoded: image.dataBase64) == Self.pngData)
    }

    @Test(arguments: [
        "",
        ".",
        "..",
        "../outside.png",
        "public/../outside.png",
        "/tmp/outside.png",
        "file:///tmp/outside.png",
        "https://example.com/image.png",
        "~/image.png",
        "public//image.png",
        "public\\image.png",
        "public/image.png?raw=1",
        "public/image.png#preview",
    ])
    func rejectsNonRelativeOrAmbiguousPaths(path: String) throws {
        let sandbox = try makeSandbox(named: "path")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }

        #expect(throws: SupermuxHarnessImageReaderError.unavailable) {
            _ = try sandbox.reader.read(relativePath: path)
        }
    }

    @Test func rejectsIntermediateAndFinalSymlinksEvenWhenTargetsStayInRoot() throws {
        let sandbox = try makeSandbox(named: "symlinks")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let direct = sandbox.root.appendingPathComponent("direct", isDirectory: true)
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        let target = direct.appendingPathComponent("target.png")
        try Self.pngData.write(to: target)

        let finalLink = direct.appendingPathComponent("final.png")
        try FileManager.default.createSymbolicLink(at: finalLink, withDestinationURL: target)
        let directoryLink = sandbox.root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: direct)

        #expect(throws: SupermuxHarnessImageReaderError.unavailable) {
            _ = try sandbox.reader.read(relativePath: "direct/final.png")
        }
        #expect(throws: SupermuxHarnessImageReaderError.unavailable) {
            _ = try sandbox.reader.read(relativePath: "linked/target.png")
        }
    }

    @Test func rejectsDirectoriesFifosAndNonImagePayloads() throws {
        let sandbox = try makeSandbox(named: "types")
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let directory = sandbox.root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appendingPathComponent("pipe.png")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        try Data("<html>private</html>".utf8).write(
            to: directory.appendingPathComponent("renamed.png")
        )
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(
            to: directory.appendingPathComponent("vector.svg")
        )

        for path in ["assets", "assets/pipe.png", "assets/renamed.png", "assets/vector.svg"] {
            #expect(throws: SupermuxHarnessImageReaderError.unavailable) {
                _ = try sandbox.reader.read(relativePath: path)
            }
        }
    }

    @Test func enforcesNonEmptyAndInclusiveByteLimit() throws {
        let sandbox = try makeSandbox(named: "limits", maximumBytes: Self.pngData.count)
        defer { try? FileManager.default.removeItem(at: sandbox.container) }
        let exact = sandbox.root.appendingPathComponent("exact.png")
        let empty = sandbox.root.appendingPathComponent("empty.png")
        try Self.pngData.write(to: exact)
        try Data().write(to: empty)

        #expect(try sandbox.reader.read(relativePath: "exact.png").mediaType == "image/png")
        #expect(throws: SupermuxHarnessImageReaderError.unavailable) {
            _ = try sandbox.reader.read(relativePath: "empty.png")
        }

        let smallerReader = SupermuxHarnessImageReader(
            rootURL: sandbox.root,
            maximumBytes: Self.pngData.count - 1
        )
        #expect(throws: SupermuxHarnessImageReaderError.unavailable) {
            _ = try smallerReader.read(relativePath: "exact.png")
        }
    }

    @Test func resolvesOnlyTheTrustedRootSymlinkBeforeWalkingChildren() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-image-root-\(UUID().uuidString)", isDirectory: true)
        let physicalRoot = container.appendingPathComponent("physical", isDirectory: true)
        let linkedRoot = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: physicalRoot)
        defer { try? FileManager.default.removeItem(at: container) }
        try Self.pngData.write(to: physicalRoot.appendingPathComponent("image.png"))
        let reader = SupermuxHarnessImageReader(rootURL: linkedRoot)

        let image = try reader.read(relativePath: "./image.png")

        #expect(image.mediaType == "image/png")
    }

    private struct Sandbox {
        let container: URL
        let root: URL
        let reader: SupermuxHarnessImageReader
    }

    private static let pngData: Data = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Unable to generate one-pixel PNG fixture")
        }
        return png
    }()

    private func makeSandbox(
        named name: String,
        maximumBytes: Int = SupermuxHarnessAttachmentPolicy.maximumImageBytes
    ) throws -> Sandbox {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-image-\(name)-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Sandbox(
            container: container,
            root: root,
            reader: SupermuxHarnessImageReader(
                rootURL: root,
                maximumBytes: maximumBytes
            )
        )
    }
}

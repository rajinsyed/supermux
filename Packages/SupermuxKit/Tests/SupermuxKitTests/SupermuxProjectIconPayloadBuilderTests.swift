import AppKit
import Foundation
import Testing
@testable import SupermuxKit

/// Etag/PNG behavior of the `mobile.supermux.project.icon` payload core
/// (validation contract RPC-PROJ-03): the first fetch returns base64 PNG bytes
/// plus a stable etag; a refetch presenting that etag short-circuits to
/// `notModified` with no image data; a missing icon reports `notFound`.
struct SupermuxProjectIconPayloadBuilderTests {
    /// A fresh, unique temp directory created on disk.
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func customIconFirstFetchReturnsBase64PNGAndEtagThenNotModified() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iconURL = dir.appendingPathComponent("custom-icon.png")
        let pngFixture = SupermuxIconTestFixtures.pngData()
        try pngFixture.write(to: iconURL)
        let builder = SupermuxProjectIconPayloadBuilder()

        let first = builder.payload(
            rootPath: dir.path,
            customIconPath: iconURL.path,
            ifNoneMatch: nil
        )

        guard case let .icon(pngBase64, etag) = first else {
            Issue.record("expected .icon, got \(first)")
            return
        }
        #expect(!etag.isEmpty)
        let decoded = try #require(Data(base64Encoded: pngBase64))
        #expect(decoded.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "payload must be PNG bytes")
        #expect(decoded == pngFixture, "a PNG source passes through byte-identical")

        let second = builder.payload(
            rootPath: dir.path,
            customIconPath: iconURL.path,
            ifNoneMatch: etag
        )
        #expect(second == .notModified(etag: etag))
    }

    @Test func staleEtagReturnsFreshIcon() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iconURL = dir.appendingPathComponent("custom-icon.png")
        try SupermuxIconTestFixtures.pngData().write(to: iconURL)
        let builder = SupermuxProjectIconPayloadBuilder()

        let result = builder.payload(
            rootPath: dir.path,
            customIconPath: iconURL.path,
            ifNoneMatch: "stale-etag"
        )

        guard case let .icon(_, etag) = result else {
            Issue.record("expected .icon for a stale etag, got \(result)")
            return
        }
        #expect(etag != "stale-etag")
    }

    @Test func nonPNGSourceConvertsToPNG() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iconURL = dir.appendingPathComponent("logo.tiff")
        let tiff = try #require(SupermuxIconTestFixtures.bitmap().tiffRepresentation)
        try tiff.write(to: iconURL)
        let builder = SupermuxProjectIconPayloadBuilder()

        let result = builder.payload(
            rootPath: dir.path,
            customIconPath: iconURL.path,
            ifNoneMatch: nil
        )

        guard case let .icon(pngBase64, _) = result else {
            Issue.record("expected .icon, got \(result)")
            return
        }
        let decoded = try #require(Data(base64Encoded: pngBase64))
        #expect(decoded.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "non-PNG sources are re-encoded as PNG")
    }

    @Test func autoDetectedRepositoryLogoIsServedWithoutCustomPath() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SupermuxIconTestFixtures.pngData().write(to: dir.appendingPathComponent("favicon.png"))
        let builder = SupermuxProjectIconPayloadBuilder()

        let result = builder.payload(rootPath: dir.path, customIconPath: nil, ifNoneMatch: nil)

        guard case .icon = result else {
            Issue.record("expected the auto-detected repository logo, got \(result)")
            return
        }
    }

    @Test func missingIconReportsNotFound() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = SupermuxProjectIconPayloadBuilder()

        let result = builder.payload(rootPath: dir.path, customIconPath: nil, ifNoneMatch: nil)

        #expect(result == .notFound)
    }

    @Test func unreadableImageDataReportsNotFound() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iconURL = dir.appendingPathComponent("icon.png")
        try Data("not an image".utf8).write(to: iconURL)
        let builder = SupermuxProjectIconPayloadBuilder()

        let result = builder.payload(
            rootPath: dir.path,
            customIconPath: iconURL.path,
            ifNoneMatch: nil
        )

        #expect(result == .notFound)
    }
}

/// Shared tiny image fixtures for the icon payload tests.
enum SupermuxIconTestFixtures {
    /// A 4×4 opaque bitmap.
    static func bitmap() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        if let data = rep.bitmapData {
            for index in 0..<(4 * 4 * 4) {
                data[index] = UInt8(truncatingIfNeeded: index &* 37 &+ 11)
            }
        }
        return rep
    }

    /// The fixture bitmap encoded as PNG bytes.
    static func pngData() -> Data {
        bitmap().representation(using: .png, properties: [:])!
    }
}

internal import AppKit
internal import CryptoKit
public import Foundation

/// Resolves a project's icon into the `mobile.supermux.project.icon` payload:
/// base64 PNG bytes plus a content etag, with a `not_modified` short-circuit
/// when the caller's etag still matches.
///
/// The etag is a SHA-256 digest of the *source* file bytes, so it is stable
/// across calls (re-encoding is skipped entirely on an etag match) and changes
/// whenever the icon file's contents change. Sources that are not already PNG
/// (SVG excepted — `NSImage` renders what it can) are re-encoded as PNG so the
/// phone always receives one format.
public struct SupermuxProjectIconPayloadBuilder: Sendable {
    private let resolver: SupermuxProjectIconResolver

    /// Creates a builder.
    /// - Parameter resolver: Locates the icon file (custom path first, then
    ///   the auto-detected repository logo).
    public init(resolver: SupermuxProjectIconResolver = SupermuxProjectIconResolver()) {
        self.resolver = resolver
    }

    /// Resolves the icon payload for one project.
    ///
    /// - Parameters:
    ///   - rootPath: Absolute path to the project root.
    ///   - customIconPath: The project's user-chosen icon file path, or `nil`.
    ///   - ifNoneMatch: The etag the caller already holds, or `nil` for an
    ///     unconditional fetch.
    /// - Returns: The payload outcome (icon bytes, `notModified`, or `notFound`).
    public func payload(
        rootPath: String,
        customIconPath: String?,
        ifNoneMatch: String?
    ) -> SupermuxProjectIconPayload {
        guard let url = resolver.resolveAvatar(rootPath: rootPath, customIconPath: customIconPath),
              let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        let etag = Self.etag(for: data)
        if let ifNoneMatch, ifNoneMatch == etag {
            return .notModified(etag: etag)
        }
        guard let png = Self.pngData(from: data) else {
            return .notFound
        }
        return .icon(pngBase64: png.base64EncodedString(), etag: etag)
    }

    /// SHA-256 hex digest of the source bytes.
    private static func etag(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// PNG magic bytes (`\x89PNG`).
    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

    /// Returns the bytes as PNG: pass-through when the source already is PNG,
    /// otherwise decoded via `NSImage` and re-encoded. `nil` when the source
    /// does not decode as an image.
    private static func pngData(from data: Data) -> Data? {
        if data.prefix(4) == pngMagic {
            return data
        }
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}

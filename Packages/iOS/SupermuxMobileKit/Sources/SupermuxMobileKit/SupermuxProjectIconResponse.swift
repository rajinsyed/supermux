public import Foundation

/// Typed decoder for the `mobile.supermux.project.icon` RPC result.
///
/// The Mac speaks raw wire keys here (no shared DTO exists in
/// SupermuxMobileCore): `{not_modified: Bool, etag: String,
/// png_base64: String?}` — `png_base64` is absent on an etag match
/// (see `Sources/Supermux/SupermuxMobileHost+Projects.swift`).
public struct SupermuxProjectIconResponse: Codable, Sendable, Equatable {
    /// `true` when the caller's etag still matches; no image data returned.
    public var notModified: Bool?
    /// The icon's cache etag (SHA-256 of the source bytes, Mac-side).
    public var etag: String?
    /// The icon as base64 PNG bytes; absent on an etag match.
    public var pngBase64: String?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - notModified: Whether the caller's etag still matches.
    ///   - etag: The icon's cache etag.
    ///   - pngBase64: The icon as base64 PNG bytes.
    public init(notModified: Bool? = nil, etag: String? = nil, pngBase64: String? = nil) {
        self.notModified = notModified
        self.etag = etag
        self.pngBase64 = pngBase64
    }

    /// The decoded PNG bytes, or `nil` when no (valid) image data traveled.
    public var pngData: Data? {
        pngBase64.flatMap { Data(base64Encoded: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case notModified = "not_modified"
        case etag
        case pngBase64 = "png_base64"
    }
}

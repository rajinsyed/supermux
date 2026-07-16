/// Outcome of resolving a project icon for `mobile.supermux.project.icon`.
public enum SupermuxProjectIconPayload: Equatable, Sendable {
    /// No fetchable icon image exists (or it failed to decode as an image).
    case notFound
    /// The caller's etag still matches; no image data is returned.
    case notModified(etag: String)
    /// The icon as base64 PNG bytes plus its cache etag.
    case icon(pngBase64: String, etag: String)
}

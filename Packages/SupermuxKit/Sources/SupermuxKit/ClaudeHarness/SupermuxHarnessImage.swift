/// An image attached to a stream-json user message.
public struct SupermuxHarnessImage: Equatable, Sendable {
    /// The MIME type, such as `image/png`.
    public let mediaType: String
    /// Base64-encoded image bytes without a data-URL prefix.
    public let dataBase64: String

    /// Creates an image attachment.
    ///
    /// - Parameters:
    ///   - mediaType: The image MIME type.
    ///   - dataBase64: The base64 payload.
    public init(mediaType: String, dataBase64: String) {
        self.mediaType = mediaType
        self.dataBase64 = dataBase64
    }
}

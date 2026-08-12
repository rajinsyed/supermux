import Foundation

/// An image attachment submitted with a Claude harness prompt.
public struct SupermuxClaudeAttachmentDTO: Codable, Sendable, Equatable {
    /// Supported image encodings.
    public enum Format: String, Codable, Sendable, Equatable {
        /// Portable Network Graphics.
        case png
        /// Joint Photographic Experts Group image.
        case jpeg
    }

    /// Raw image bytes, encoded as base64 on the wire.
    public var data: Data
    /// Image encoding.
    public var format: Format

    /// Creates a prompt image attachment.
    /// - Parameters:
    ///   - data: Raw image bytes.
    ///   - format: Image encoding.
    public init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case data = "data_b64"
        case format
    }
}

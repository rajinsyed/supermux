import Foundation

/// One bounded chunk returned by `mobile.supermux.claude.tool_payload`.
///
/// Raw chunk data is capped below the mobile sync frame limit and encodes as
/// base64 under `data_b64`.
public struct SupermuxClaudeToolPayloadChunkDTO: Codable, Sendable, Equatable {
    /// Maximum raw bytes carried by one chunk.
    public static let maximumDataBytes = 3 * 1024 * 1024

    /// Raw payload bytes.
    public let data: Data
    /// Byte offset of this chunk in the complete payload.
    public let offset: Int64
    /// Total raw payload size in bytes.
    public let totalSize: Int64
    /// Whether this is the final chunk.
    public let eof: Bool

    /// Creates a validated tool-payload chunk.
    /// - Parameters:
    ///   - data: Raw payload bytes, no larger than ``maximumDataBytes``.
    ///   - offset: Byte offset in the complete payload.
    ///   - totalSize: Total raw payload size.
    ///   - eof: Whether this is the final chunk.
    /// - Throws: ``SupermuxClaudeToolPayloadChunkError/chunkTooLarge(actualBytes:)`` when `data` exceeds the limit.
    public init(data: Data, offset: Int64, totalSize: Int64, eof: Bool) throws {
        guard data.count <= Self.maximumDataBytes else {
            throw SupermuxClaudeToolPayloadChunkError.chunkTooLarge(actualBytes: data.count)
        }
        self.data = data
        self.offset = offset
        self.totalSize = totalSize
        self.eof = eof
    }

    private enum CodingKeys: String, CodingKey {
        case data = "data_b64"
        case offset
        case totalSize = "total_size"
        case eof
    }

    /// Decodes and validates a bounded tool-payload chunk.
    /// - Parameter decoder: The decoder supplying the chunk object.
    /// - Throws: ``SupermuxClaudeToolPayloadChunkError/chunkTooLarge(actualBytes:)`` when decoded data exceeds the limit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            data: container.decode(Data.self, forKey: .data),
            offset: container.decode(Int64.self, forKey: .offset),
            totalSize: container.decode(Int64.self, forKey: .totalSize),
            eof: container.decode(Bool.self, forKey: .eof)
        )
    }

    /// Encodes the validated chunk using the mobile wire keys.
    /// - Parameter encoder: The encoder receiving the chunk object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(offset, forKey: .offset)
        try container.encode(totalSize, forKey: .totalSize)
        try container.encode(eof, forKey: .eof)
    }
}

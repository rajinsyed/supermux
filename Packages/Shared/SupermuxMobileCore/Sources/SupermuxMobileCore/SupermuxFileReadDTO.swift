/// Wire representation of one `files.read` chunk.
///
/// A reader asks for consecutive chunks until `eof`; `size` and
/// `modifiedAt` describe the file when the chunk was read, so a reader can
/// notice the file changing under it and start over.
public struct SupermuxFileReadDTO: Codable, Sendable, Equatable {
    /// The file, root-relative.
    public var path: String
    /// The file's size in bytes.
    public var size: Int
    /// The file's modification time, Unix seconds.
    public var modifiedAt: Double
    /// Where this chunk starts.
    public var offset: Int
    /// How many bytes this chunk holds.
    public var length: Int
    /// Whether this chunk reaches the end of the file.
    public var eof: Bool
    /// The chunk's bytes, base64.
    public var data: String

    /// Creates a read-chunk DTO.
    /// - Parameters:
    ///   - path: The file, root-relative.
    ///   - size: The file's size in bytes.
    ///   - modifiedAt: The file's modification time, Unix seconds.
    ///   - offset: Where the chunk starts.
    ///   - length: How many bytes the chunk holds.
    ///   - eof: Whether the chunk reaches the end of the file.
    ///   - data: The chunk's bytes, base64.
    public init(path: String, size: Int, modifiedAt: Double, offset: Int, length: Int, eof: Bool, data: String) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.offset = offset
        self.length = length
        self.eof = eof
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case size
        case modifiedAt = "modified_at"
        case offset
        case length
        case eof
        case data
    }
}

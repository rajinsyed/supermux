/// Wire representation of one file's diff.
///
/// Text files carry a unified diff in ``diffText``; binary files set
/// ``isBinary`` and carry no diff text. Oversized diffs are byte-capped on
/// the Mac and flagged via ``truncated``.
public struct SupermuxDiffDTO: Codable, Sendable, Equatable {
    /// Repo-relative path of the diffed file.
    public var path: String
    /// Whether the file is binary (no textual diff available).
    public var isBinary: Bool?
    /// Unified diff text; `nil` for binary files.
    public var diffText: String?
    /// Whether ``diffText`` was cut off at the host's byte cap.
    public var truncated: Bool?

    /// Creates a diff DTO.
    /// - Parameters:
    ///   - path: Repo-relative path of the diffed file.
    ///   - isBinary: Optional binary flag.
    ///   - diffText: Optional unified diff text.
    ///   - truncated: Optional truncation flag.
    public init(
        path: String,
        isBinary: Bool? = nil,
        diffText: String? = nil,
        truncated: Bool? = nil
    ) {
        self.path = path
        self.isBinary = isBinary
        self.diffText = diffText
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case isBinary = "is_binary"
        case diffText = "diff_text"
        case truncated
    }
}

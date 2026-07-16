/// Wire representation of one directory entry in the phone's file browser.
public struct SupermuxFileEntryDTO: Codable, Sendable, Equatable {
    /// Entry name (last path component); the identity within its directory.
    public var name: String
    /// Whether the entry is a directory.
    public var isDir: Bool?
    /// Whether the entry is a symbolic link.
    public var isSymlink: Bool?
    /// File size in bytes; `nil` for directories or when unknown.
    public var size: Int?
    /// Last modification time, Unix seconds.
    public var modifiedAt: Double?

    /// Creates a file-entry DTO.
    /// - Parameters:
    ///   - name: Entry name (last path component).
    ///   - isDir: Optional directory flag.
    ///   - isSymlink: Optional symlink flag.
    ///   - size: Optional size in bytes.
    ///   - modifiedAt: Optional modification time, Unix seconds.
    public init(
        name: String,
        isDir: Bool? = nil,
        isSymlink: Bool? = nil,
        size: Int? = nil,
        modifiedAt: Double? = nil
    ) {
        self.name = name
        self.isDir = isDir
        self.isSymlink = isSymlink
        self.size = size
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case isDir = "is_dir"
        case isSymlink = "is_symlink"
        case size
        case modifiedAt = "modified_at"
    }
}

/// Wire representation of a `files.list` result.
///
/// `home` is the host's home folder (additive), so another Mac's Files panel
/// can abbreviate the root as `~/…` exactly like the desktop panel does.
public struct SupermuxFileListDTO: Codable, Sendable, Equatable {
    /// The listed directory, root-relative (`""` for the root).
    public var path: String
    /// The directory's entries, directories first, then by name.
    public var entries: [SupermuxFileEntryDTO]
    /// The host's home folder; `nil` from hosts that predate it.
    public var home: String?
    /// `true` when the folder holds more entries than the listing returns.
    public var truncated: Bool?

    /// Creates a listing DTO.
    /// - Parameters:
    ///   - path: The listed directory, root-relative.
    ///   - entries: The directory's entries.
    ///   - home: The host's home folder.
    ///   - truncated: Whether the folder holds more entries.
    public init(path: String, entries: [SupermuxFileEntryDTO], home: String? = nil, truncated: Bool? = nil) {
        self.path = path
        self.entries = entries
        self.home = home
        self.truncated = truncated
    }
}

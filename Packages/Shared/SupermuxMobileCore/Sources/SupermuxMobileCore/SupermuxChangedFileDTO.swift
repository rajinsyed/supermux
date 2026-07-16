/// Wire representation of a single changed file inside a repository.
///
/// Mirrors the Mac's `SupermuxGitFileChange`. ``kind`` carries the change
/// kind's raw string (`modified`, `added`, `deleted`, `renamed`, `copied`,
/// `untracked`, `conflicted`, `typeChanged`) and stays a plain string so new
/// kinds never break decoding on old peers.
public struct SupermuxChangedFileDTO: Codable, Sendable, Equatable {
    /// Repo-relative path of the (new) file; the stable identity.
    public var path: String
    /// Repo-relative source path for renames and copies, otherwise `nil`.
    public var oldPath: String?
    /// The kind of change git reported.
    public var kind: String?

    /// Creates a changed-file DTO.
    /// - Parameters:
    ///   - path: Repo-relative path of the (new) file.
    ///   - oldPath: Optional source path for renames/copies.
    ///   - kind: Optional change kind string.
    public init(path: String, oldPath: String? = nil, kind: String? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case kind
    }
}

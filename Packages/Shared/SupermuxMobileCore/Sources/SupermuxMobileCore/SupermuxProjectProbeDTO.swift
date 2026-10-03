/// Result of `mobile.supermux.project.probe`: what a folder is on the host Mac.
///
/// Another Mac uses it to decide whether the host already has its own copy of
/// a repository at the same path (project sync registers it only when the
/// folder is a git repo with the same origin), and never clones or deletes on
/// the strength of it. Only ``rootPath`` and the three flags are required.
public struct SupermuxProjectProbeDTO: Codable, Sendable, Equatable {
    /// The probed folder, standardized by the host.
    public var rootPath: String
    /// Whether anything exists at ``rootPath``.
    public var exists: Bool
    /// Whether ``rootPath`` is a folder.
    public var isDirectory: Bool
    /// Whether ``rootPath`` is inside a git work tree.
    public var isGitRepo: Bool
    /// The repository's `origin` URL, when it has one.
    public var gitRemoteURL: String?
    /// Whether the host's user removed a project at this root, so project
    /// sync must not register it again. `nil` from hosts that do not track it.
    public var isSuppressed: Bool?

    /// Device-independent repository key derived from ``gitRemoteURL``.
    public var gitRemoteIdentity: String? { SupermuxGitRemoteIdentity.normalized(gitRemoteURL) }

    /// Creates a probe result.
    /// - Parameters:
    ///   - rootPath: The probed folder.
    ///   - exists: Whether anything exists there.
    ///   - isDirectory: Whether it is a folder.
    ///   - isGitRepo: Whether it is inside a git work tree.
    ///   - gitRemoteURL: The `origin` URL, if any.
    ///   - isSuppressed: Whether project sync must skip this root.
    public init(
        rootPath: String,
        exists: Bool,
        isDirectory: Bool,
        isGitRepo: Bool,
        gitRemoteURL: String? = nil,
        isSuppressed: Bool? = nil
    ) {
        self.rootPath = rootPath
        self.exists = exists
        self.isDirectory = isDirectory
        self.isGitRepo = isGitRepo
        self.gitRemoteURL = gitRemoteURL
        self.isSuppressed = isSuppressed
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath = "root_path"
        case exists
        case isDirectory = "is_directory"
        case isGitRepo = "is_git_repo"
        case gitRemoteURL = "git_remote_url"
        case isSuppressed = "is_suppressed"
    }
}

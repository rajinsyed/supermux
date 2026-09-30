/// Wire representation of a `files.git_status` result: the colors the
/// desktop Files panel gives its rows (a changed file's folders included).
public struct SupermuxFileGitStatusDTO: Codable, Sendable, Equatable {
    /// Whether the folder is inside a git repository.
    public var isRepository: Bool
    /// Whether the host stopped waiting for git at its time bound.
    public var timedOut: Bool?
    /// One entry per decorated path.
    public var statuses: [SupermuxFileGitStatusEntryDTO]

    /// Creates a git-status DTO.
    /// - Parameters:
    ///   - isRepository: Whether the folder is inside a git repository.
    ///   - timedOut: Whether the host stopped waiting for git.
    ///   - statuses: One entry per decorated path.
    public init(isRepository: Bool, timedOut: Bool? = nil, statuses: [SupermuxFileGitStatusEntryDTO]) {
        self.isRepository = isRepository
        self.timedOut = timedOut
        self.statuses = statuses
    }

    private enum CodingKeys: String, CodingKey {
        case isRepository = "is_repository"
        case timedOut = "timed_out"
        case statuses
    }
}

/// One decorated path in a `files.git_status` result.
public struct SupermuxFileGitStatusEntryDTO: Codable, Sendable, Equatable {
    /// The path, root-relative.
    public var path: String
    /// `modified`, `added`, `deleted`, `renamed` or `untracked`.
    public var status: String

    /// Creates a git-status entry DTO.
    /// - Parameters:
    ///   - path: The path, root-relative.
    ///   - status: The git status name.
    public init(path: String, status: String) {
        self.path = path
        self.status = status
    }
}

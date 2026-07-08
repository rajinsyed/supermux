/// Wire representation of a single commit from a repository's history.
///
/// Mirrors the Mac's `SupermuxGitCommit`. ``relativeDate`` is git's own
/// humanized form (e.g. `"2 hours ago"`), captured Mac-side at read time.
public struct SupermuxCommitDTO: Codable, Sendable, Equatable {
    /// Full commit hash; the stable identity.
    public var sha: String
    /// Abbreviated commit hash for compact display.
    public var shortSha: String?
    /// Commit author name.
    public var author: String?
    /// Humanized relative author date from git (e.g. `"3 days ago"`).
    public var relativeDate: String?
    /// First line of the commit message.
    public var subject: String?
    /// Whether the commit is already on the upstream.
    public var isPushed: Bool?

    /// Creates a commit DTO.
    /// - Parameters:
    ///   - sha: Full commit hash.
    ///   - shortSha: Optional abbreviated hash.
    ///   - author: Optional author name.
    ///   - relativeDate: Optional humanized relative date.
    ///   - subject: Optional first line of the message.
    ///   - isPushed: Optional pushed-to-upstream flag.
    public init(
        sha: String,
        shortSha: String? = nil,
        author: String? = nil,
        relativeDate: String? = nil,
        subject: String? = nil,
        isPushed: Bool? = nil
    ) {
        self.sha = sha
        self.shortSha = shortSha
        self.author = author
        self.relativeDate = relativeDate
        self.subject = subject
        self.isPushed = isPushed
    }

    private enum CodingKeys: String, CodingKey {
        case sha
        case shortSha = "short_sha"
        case author
        case relativeDate = "relative_date"
        case subject
        case isPushed = "is_pushed"
    }
}

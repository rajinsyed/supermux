import Foundation

/// A single commit from a repository's history, as reported by `git log`.
///
/// Carries only the small set of fields the Changes panel's history section
/// renders. The relative date is git's own humanized form (e.g. "2 hours
/// ago"), captured at read time and refreshed whenever the log is reloaded.
public struct SupermuxGitCommit: Identifiable, Hashable, Sendable {
    /// Full 40-character commit hash; the stable identity.
    public let hash: String
    /// Abbreviated commit hash for compact display.
    public let shortHash: String
    /// Commit author name.
    public let author: String
    /// Humanized relative author date from git (e.g. "3 days ago").
    public let relativeDate: String
    /// First line of the commit message (may be empty).
    public let subject: String

    /// Stable identity: the full commit hash.
    public var id: String { hash }

    /// Creates a commit.
    /// - Parameters:
    ///   - hash: Full commit hash.
    ///   - shortHash: Abbreviated commit hash.
    ///   - author: Author name.
    ///   - relativeDate: Humanized relative date from git.
    ///   - subject: First line of the commit message.
    public init(hash: String, shortHash: String, author: String, relativeDate: String, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.relativeDate = relativeDate
        self.subject = subject
    }

    /// Number of fields each commit contributes to the parsed token stream.
    private static let fieldCount = 5

    /// `git log --format=` template: the five fields separated by `%x00`, which
    /// git emits as NUL bytes. Paired with `-z` (each commit record is also
    /// NUL-terminated), so the whole output is one flat NUL-separated stream —
    /// no field can contain a NUL, so author names and subjects with spaces (or
    /// even newlines) parse unambiguously.
    ///
    /// Uses the `%x00` *placeholder text* rather than a literal NUL character:
    /// a literal NUL embedded in a command-line argument would truncate the
    /// argument (argv strings are NUL-terminated).
    public static let logFormat = "%H%x00%h%x00%an%x00%ar%x00%s"

    /// Parses `git log -z --format=\(logFormat)` stdout into commits.
    ///
    /// Splits the stream on NUL and reads it in groups of five fields. A group
    /// whose hash is empty (the trailing terminator, or malformed output) ends
    /// parsing, so partial output still yields the commits that were complete.
    /// Empty stdout parses to `[]`.
    /// - Parameter output: Raw stdout from `git log -z --format=\(logFormat)`.
    public static func parse(log output: String) -> [SupermuxGitCommit] {
        let fields = output.components(separatedBy: "\u{0}")
        var commits: [SupermuxGitCommit] = []
        var index = 0
        while index + fieldCount <= fields.count {
            let hash = fields[index]
            guard !hash.isEmpty else { break }
            commits.append(SupermuxGitCommit(
                hash: hash,
                shortHash: fields[index + 1],
                author: fields[index + 2],
                relativeDate: fields[index + 3],
                subject: fields[index + 4]
            ))
            index += fieldCount
        }
        return commits
    }
}

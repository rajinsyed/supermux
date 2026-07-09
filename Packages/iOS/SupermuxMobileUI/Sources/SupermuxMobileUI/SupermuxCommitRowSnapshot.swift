public import SupermuxMobileCore

/// The immutable value snapshot a history commit row renders from — rows
/// below the History list boundary hold NO store reference (snapshot-boundary
/// rule), only these values.
public struct SupermuxCommitRowSnapshot: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identity: the commit's full sha.
    public let id: String
    /// First line of the commit message, or an em dash when absent.
    public let subject: String
    /// Abbreviated sha (the DTO's `short_sha`, else the sha's first 7).
    public let shortSha: String
    /// Author name, when known.
    public let author: String?
    /// git's humanized relative date (e.g. "2 hours ago"), when known.
    public let relativeDate: String?
    /// Whether the commit is known NOT to be on the upstream yet
    /// (`is_pushed == false`; absent means no styling — m3-f2's probe cap
    /// degrades deep never-pushed history to pushed).
    public let isUnpushed: Bool

    /// Projects one wire commit into row values.
    /// - Parameter dto: The commit from `changes.history`.
    public init(dto: SupermuxCommitDTO) {
        self.id = dto.sha
        let trimmedSubject = dto.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = (trimmedSubject?.isEmpty == false) ? trimmedSubject! : "—"
        let shortSha = dto.shortSha?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shortSha = (shortSha?.isEmpty == false) ? shortSha! : String(dto.sha.prefix(7))
        self.author = dto.author
        self.relativeDate = dto.relativeDate
        self.isUnpushed = dto.isPushed == false
    }

    /// Projects one page of wire commits into row values, preserving order.
    /// - Parameter commits: The commits from `changes.history`.
    public static func rows(from commits: [SupermuxCommitDTO]) -> [SupermuxCommitRowSnapshot] {
        commits.map(SupermuxCommitRowSnapshot.init(dto:))
    }
}

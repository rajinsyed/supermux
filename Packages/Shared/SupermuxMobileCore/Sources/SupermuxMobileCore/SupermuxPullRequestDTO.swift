/// Wire representation of a pull request associated with a worktree, reduced
/// to the fields the phone's badge renders.
public struct SupermuxPullRequestDTO: Codable, Sendable, Equatable {
    /// The PR number; the stable identity.
    public var number: Int
    /// PR state (e.g. `"open"`, `"closed"`, `"merged"`, `"draft"`).
    public var state: String?
    /// PR title.
    public var title: String?
    /// Web URL of the PR.
    public var url: String?

    /// Creates a pull-request DTO.
    /// - Parameters:
    ///   - number: The PR number.
    ///   - state: Optional PR state string.
    ///   - title: Optional PR title.
    ///   - url: Optional PR web URL.
    public init(
        number: Int,
        state: String? = nil,
        title: String? = nil,
        url: String? = nil
    ) {
        self.number = number
        self.state = state
        self.title = title
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case title
        case url
    }
}

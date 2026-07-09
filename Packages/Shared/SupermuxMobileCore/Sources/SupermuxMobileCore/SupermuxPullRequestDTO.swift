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
    /// Whether the badge is stale (kept after repeated probe failures) —
    /// the mac dims a stale badge to 50% and the phone mirrors it. Optional
    /// and omitted when fresh, so pre-m6-f2 payloads decode unchanged.
    public var isStale: Bool?

    /// Creates a pull-request DTO.
    /// - Parameters:
    ///   - number: The PR number.
    ///   - state: Optional PR state string.
    ///   - title: Optional PR title.
    ///   - url: Optional PR web URL.
    ///   - isStale: Whether the badge is stale; `nil`/absent means fresh.
    public init(
        number: Int,
        state: String? = nil,
        title: String? = nil,
        url: String? = nil,
        isStale: Bool? = nil
    ) {
        self.number = number
        self.state = state
        self.title = title
        self.url = url
        self.isStale = isStale
    }

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case title
        case url
        case isStale = "is_stale"
    }
}

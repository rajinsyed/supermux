/// Wire representation of a `files.search` result.
public struct SupermuxFileSearchDTO: Codable, Sendable, Equatable {
    /// `matches`, `no_matches`, or `limited` (results stopped at a cap).
    public var status: String
    /// The cap that stopped the results, with `limited`.
    public var limit: Int?
    /// Whether the host stopped the search at its time bound.
    public var timedOut: Bool?
    /// The matches, in the order the search found them.
    public var results: [SupermuxFileSearchMatchDTO]

    /// Creates a search-result DTO.
    /// - Parameters:
    ///   - status: `matches`, `no_matches` or `limited`.
    ///   - limit: The cap that stopped the results.
    ///   - timedOut: Whether the host stopped at its time bound.
    ///   - results: The matches.
    public init(status: String, limit: Int? = nil, timedOut: Bool? = nil, results: [SupermuxFileSearchMatchDTO]) {
        self.status = status
        self.limit = limit
        self.timedOut = timedOut
        self.results = results
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case limit
        case timedOut = "timed_out"
        case results
    }
}

/// One `files.search` match.
public struct SupermuxFileSearchMatchDTO: Codable, Sendable, Equatable {
    /// The file, root-relative.
    public var path: String
    /// The 1-based line number.
    public var line: Int
    /// The 1-based column of the first match on the line.
    public var column: Int
    /// The matching line, trimmed.
    public var preview: String

    /// Creates a match DTO.
    /// - Parameters:
    ///   - path: The file, root-relative.
    ///   - line: The 1-based line number.
    ///   - column: The 1-based column of the first match.
    ///   - preview: The matching line, trimmed.
    public init(path: String, line: Int, column: Int, preview: String) {
        self.path = path
        self.line = line
        self.column = column
        self.preview = preview
    }
}

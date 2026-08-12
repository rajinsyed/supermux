/// Cumulative cost and timing totals for one Claude harness session.
public struct SupermuxClaudeCostDTO: Codable, Sendable, Equatable {
    /// Total provider-reported cost in US dollars.
    public var totalUSD: Double
    /// Number of completed turns.
    public var turns: Int
    /// Cumulative provider-reported duration in milliseconds.
    public var durationMS: Int64

    /// Creates a session cost summary.
    /// - Parameters:
    ///   - totalUSD: Total cost in US dollars.
    ///   - turns: Number of completed turns.
    ///   - durationMS: Cumulative duration in milliseconds.
    public init(totalUSD: Double, turns: Int, durationMS: Int64) {
        self.totalUSD = totalUSD
        self.turns = turns
        self.durationMS = durationMS
    }

    private enum CodingKeys: String, CodingKey {
        case totalUSD = "total_usd"
        case turns
        case durationMS = "duration_ms"
    }
}

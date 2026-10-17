public struct SupermuxOrderSortKey: Comparable, Hashable, Sendable {
    public let key: String
    public let canonicalID: String
    public let tieRank: Int
    public init(key: String, canonicalID: String, tieRank: Int) {
        self.key = key
        self.canonicalID = canonicalID
        self.tieRank = tieRank
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { false }
}

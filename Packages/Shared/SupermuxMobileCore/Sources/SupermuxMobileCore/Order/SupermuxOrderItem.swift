public struct SupermuxOrderItem<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    public let tier: Int
    public let sortKey: SupermuxOrderSortKey?
    public let unit: String
    public let isFixed: Bool
    public init(id: ID, tier: Int, sortKey: SupermuxOrderSortKey?, unit: String, isFixed: Bool = false) {
        self.id = id
        self.tier = tier
        self.sortKey = sortKey
        self.unit = unit
        self.isFixed = isFixed
    }
}

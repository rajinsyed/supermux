/// One row handed to ``SupermuxOrderArrangement/arrange(_:)``.
///
/// `ID` is whatever identifies a row to the caller: the Mac's workspace
/// `UUID`, the phone's preview id.
public struct SupermuxOrderItem<ID: Hashable & Sendable>: Sendable {
    /// The row.
    public let id: ID
    /// The row's tier: `0` pinned, `1` unpinned. Tiers never mix.
    public let tier: Int
    /// Where the row sorts, or `nil` for an unkeyed row (an old Mac, or not keyed yet).
    public let sortKey: SupermuxOrderSortKey?
    /// The block the row moves with. Members of one group share it; any
    /// other row uses its own id.
    public let unit: String
    /// Whether this arrangement must leave the row where it is (on the Mac,
    /// its own rows, locally grouped rows and unkeyed mirrors).
    public let isFixed: Bool

    /// Creates an item.
    /// - Parameters:
    ///   - id: The row.
    ///   - tier: `0` pinned, `1` unpinned.
    ///   - sortKey: Where the row sorts, or `nil` when it is unkeyed.
    ///   - unit: The block the row moves with.
    ///   - isFixed: Whether the row stays where it is. Defaults to `false`:
    ///     the phone moves every row.
    public init(id: ID, tier: Int, sortKey: SupermuxOrderSortKey?, unit: String, isFixed: Bool = false) {
        self.id = id
        self.tier = tier
        self.sortKey = sortKey
        self.unit = unit
        self.isFixed = isFixed
    }
}

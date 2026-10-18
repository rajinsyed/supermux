/// Where a row sat at the previous capture pass: its id and its tier.
///
/// The capture planner diffs the current rows against these. A row whose
/// tier changed since (pinned or unpinned) has no position in its new tier,
/// so it counts as new there.
///
/// ```swift
/// state.baseline = rows.map(\.position)   // after every pass, apply included
/// ```
public struct SupermuxOrderPosition<ID: Hashable & Sendable>: Hashable, Sendable {
    /// The row.
    public let id: ID
    /// The row's tier then: `0` pinned, `1` unpinned.
    public let tier: Int

    /// Creates a position.
    /// - Parameters:
    ///   - id: The row.
    ///   - tier: `0` pinned, `1` unpinned.
    public init(id: ID, tier: Int) {
        self.id = id
        self.tier = tier
    }
}

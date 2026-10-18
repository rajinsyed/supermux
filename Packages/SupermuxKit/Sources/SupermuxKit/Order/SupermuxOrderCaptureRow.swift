public import SupermuxMobileCore

/// One workspace row of a window, in tab order, as the capture planner sees it.
///
/// The Mac reconciler adapts its `TabManager` state into these rows, so the
/// planner stays a pure function over plain values. Use ``own(id:tier:key:canonicalID:group:)``
/// for a workspace this Mac owns and ``mirror(id:tier:key:canonicalID:canSendToOwner:group:)``
/// for a local mirror of another Mac's workspace.
///
/// ```swift
/// let row = SupermuxOrderCaptureRow.own(
///     id: workspace.id, tier: workspace.isPinned ? 0 : 1,
///     key: store.key(forStableID: workspace.stableId),
///     canonicalID: workspace.id.uuidString
/// )
/// ```
public struct SupermuxOrderCaptureRow<ID: Hashable & Sendable>: Sendable {
    /// The row.
    public let id: ID
    /// The row's rendered tier: `0` pinned, `1` unpinned.
    public let tier: Int
    /// Whether the row mirrors another Mac's workspace.
    public let isMirror: Bool
    /// The row's order key: the stored key of an own row; the pending key,
    /// else the record key, of a mirror. `nil` when it has none. A key that
    /// is not ``SupermuxOrderKey/isValid(_:)`` counts as none.
    public let key: String?
    /// The owner Mac's workspace id, the comparator's tie-break.
    public let canonicalID: String
    /// Whether a moved mirror may ask its owner to take a new key: its record
    /// carries a valid key (a capable owner), its raw pin matches the record's,
    /// and its rendered tier matches the owner's group-aware tier.
    /// Always `false` for an own row.
    public let canSendToOwner: Bool
    /// The local group the row moves with, or `nil` when it is in none: a
    /// move of one member moves the whole group.
    public let group: String?

    /// An own row.
    /// - Parameters:
    ///   - id: The row.
    ///   - tier: `0` pinned, `1` unpinned.
    ///   - key: The row's stored key, if any.
    ///   - canonicalID: This Mac's workspace id for the row.
    ///   - group: The local group the row is in, if any.
    /// - Returns: The row.
    public static func own(id: ID, tier: Int, key: String?, canonicalID: String, group: String? = nil) -> Self {
        Self(id: id, tier: tier, isMirror: false, key: key, canonicalID: canonicalID, canSendToOwner: false, group: group)
    }

    /// A mirror row.
    /// - Parameters:
    ///   - id: The row.
    ///   - tier: `0` pinned, `1` unpinned.
    ///   - key: The pending key, else the record key, if any.
    ///   - canonicalID: The owner Mac's workspace id.
    ///   - canSendToOwner: Whether a move of this mirror may be sent to its owner.
    ///   - group: The local group the row is in, if any.
    /// - Returns: The row.
    public static func mirror(
        id: ID, tier: Int, key: String?, canonicalID: String, canSendToOwner: Bool, group: String? = nil
    ) -> Self {
        Self(id: id, tier: tier, isMirror: true, key: key, canonicalID: canonicalID, canSendToOwner: canSendToOwner, group: group)
    }

    /// The row's place in the previous-pass baseline.
    public var position: SupermuxOrderPosition<ID> {
        SupermuxOrderPosition(id: id, tier: tier)
    }

    /// Where the row sorts, or `nil` when it has no valid key.
    public var sortKey: SupermuxOrderSortKey? {
        validKey.map { sortKey(withKey: $0) }
    }

    /// The row's key when it is valid.
    var validKey: String? {
        key.flatMap { SupermuxOrderKey().isValid($0) ? $0 : nil }
    }

    /// Where the row would sort under `key`.
    func sortKey(withKey key: String) -> SupermuxOrderSortKey {
        SupermuxOrderSortKey(key: key, canonicalID: canonicalID, tieRank: isMirror ? 1 : 0)
    }
}

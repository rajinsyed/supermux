/// Where a keyed workspace row sorts: its order key, then its owner's
/// workspace id, then own-before-mirror. Every Mac and the phone compare rows
/// with this one comparator, so they agree even on equal keys.
///
/// ```swift
/// let own = SupermuxOrderSortKey(key: "a1", canonicalID: workspace.id.uuidString, tieRank: 0)
/// let mirror = SupermuxOrderSortKey(key: "a1", canonicalID: remoteID, tieRank: 1)
/// own < mirror  // a loopback mirror sits right after its source
/// ```
public struct SupermuxOrderSortKey: Comparable, Hashable, Sendable {
    /// The row's ``SupermuxOrderKey``.
    public let key: String
    /// The owner Mac's workspace id, uppercased so the Mac and the phone break ties alike.
    public let canonicalID: String
    /// `0` for a row this device owns, `1` for a mirror of another Mac's row.
    /// Only a Mac sees both, for loopback twins that share a key and an id.
    public let tieRank: Int

    /// Creates a sort key.
    /// - Parameters:
    ///   - key: The row's order key.
    ///   - canonicalID: The owner Mac's workspace id, in any case.
    ///   - tieRank: `0` for an own row, `1` for a mirror.
    public init(key: String, canonicalID: String, tieRank: Int) {
        self.key = key
        self.canonicalID = canonicalID.uppercased()
        self.tieRank = tieRank
    }

    /// Key, then canonical id, both in byte order, then tie rank.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.key != rhs.key {
            return lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        if lhs.canonicalID != rhs.canonicalID {
            return lhs.canonicalID.utf8.lexicographicallyPrecedes(rhs.canonicalID.utf8)
        }
        return lhs.tieRank < rhs.tieRank
    }
}

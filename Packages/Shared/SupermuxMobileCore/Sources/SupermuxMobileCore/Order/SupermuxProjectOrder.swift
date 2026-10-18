/// Puts projects in the shared order: stamped projects by their
/// ``SupermuxOrderStamp``, then unstamped ones in the order they came in.
///
/// Ties break on the stamp's own fields, never on project ids, so the Mac's
/// unified ids and the phone's merge ids never have to agree.
///
/// ```swift
/// let shown = SupermuxProjectOrder().sorted(merged) { effectiveStamp(of: $0) }
/// ```
public struct SupermuxProjectOrder: Sendable {
    /// Creates the order.
    public init() {}

    /// The items in the shared order.
    /// - Parameters:
    ///   - items: The items in today's order, the fallback for unstamped ones.
    ///   - stamp: An item's effective stamp, or `nil`. A stamp that is not valid counts as none.
    /// - Returns: Stamped items by `(key, updatedAt, origin)`, then the rest in input order.
    public func sorted<T>(_ items: [T], stamp: (T) -> SupermuxOrderStamp?) -> [T] {
        let stamps = items.map { stamp($0).flatMap { $0.isValid ? $0 : nil } }
        let stamped = items.indices
            .compactMap { index in stamps[index].map { (stamp: $0, index: index) } }
            .sorted { lhs, rhs in
                if Self.precedes(lhs.stamp, rhs.stamp) { return true }
                if Self.precedes(rhs.stamp, lhs.stamp) { return false }
                return lhs.index < rhs.index
            }
            .map { items[$0.index] }
        let unstamped = items.indices.filter { stamps[$0] == nil }.map { items[$0] }
        return stamped + unstamped
    }

    /// Key, then time, then origin; keys and origins in byte order.
    private static func precedes(_ lhs: SupermuxOrderStamp, _ rhs: SupermuxOrderStamp) -> Bool {
        if lhs.key != rhs.key {
            return lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.origin.utf8.lexicographicallyPrecedes(rhs.origin.utf8)
    }
}

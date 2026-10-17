/// Puts rows in the shared order. The Mac (placing mirrors among its own
/// rows) and the phone (showing every Mac's rows) use this one function, so
/// they agree.
///
/// Tier by tier, ascending, each tier taken in input order:
/// - **Units.** Moving rows with the same ``SupermuxOrderItem/unit`` gather
///   into one unit at the first member's position. Fixed rows form units only
///   from contiguous runs. A unit with any fixed member is fixed. A unit's
///   rank is the lowest sort key among its members.
/// - **Fixed units** keep their order. Each **moving ranked unit**, by rank, is
///   placed right before the first fixed unit that ranks higher, so it lands
///   only between units, never inside one. A fixed unit with no rank stays
///   in place and places nothing.
/// - The ranked moving units left over follow, then the unranked moving units
///   in input order.
/// - Members of a moving unit sort by key, unkeyed members last in input
///   order. Members of a fixed unit keep their order.
///
/// ```swift
/// // The Mac: own rows fixed, keyed mirrors move.
/// let desired = SupermuxOrderArrangement().arrange(rows.applyItems)
/// ```
public struct SupermuxOrderArrangement: Sendable {
    /// Creates the arrangement.
    public init() {}

    /// The rows' ids in the shared order.
    /// - Parameter items: The rows in their current order.
    /// - Returns: Every id once: the lower tier first, each tier arranged as described above.
    public func arrange<ID>(_ items: [SupermuxOrderItem<ID>]) -> [ID] {
        Set(items.map(\.tier)).sorted().flatMap { tier in
            arrangeTier(items.filter { $0.tier == tier })
        }
    }

    private func arrangeTier<ID>(_ items: [SupermuxOrderItem<ID>]) -> [ID] {
        let units = Unit<ID>.units(of: items)
        let moving = units.filter { !$0.isFixed }
        var ranked = moving.enumerated()
            .compactMap { offset, unit in unit.rank.map { (rank: $0, offset: offset, unit: unit) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }[...]
        var arranged: [ID] = []
        for unit in units where unit.isFixed {
            if let rank = unit.rank {
                while let next = ranked.first, next.rank < rank {
                    arranged += next.unit.orderedIDs
                    ranked.removeFirst()
                }
            }
            arranged += unit.orderedIDs
        }
        arranged += ranked.flatMap { $0.unit.orderedIDs }
        arranged += moving.filter { $0.rank == nil }.flatMap(\.orderedIDs)
        return arranged
    }
}

extension SupermuxOrderArrangement {
    /// Rows that move as one block.
    fileprivate struct Unit<ID: Hashable & Sendable> {
        let isFixed: Bool
        private(set) var members: [SupermuxOrderItem<ID>]
        /// The lowest sort key among the members.
        private(set) var rank: SupermuxOrderSortKey?

        init(_ member: SupermuxOrderItem<ID>, isFixed: Bool) {
            self.isFixed = isFixed
            members = [member]
            rank = member.sortKey
        }

        mutating func append(_ member: SupermuxOrderItem<ID>) {
            members.append(member)
            if let key = member.sortKey, rank.map({ key < $0 }) ?? true {
                rank = key
            }
        }

        /// Fixed: input order. Moving: by key, unkeyed members last in input order.
        var orderedIDs: [ID] {
            guard !isFixed else { return members.map(\.id) }
            let keyed = members.enumerated()
                .compactMap { offset, member in member.sortKey.map { (key: $0, offset: offset, id: member.id) } }
                .sorted { ($0.key, $0.offset) < ($1.key, $1.offset) }
                .map { $0.id }
            return keyed + members.filter { $0.sortKey == nil }.map(\.id)
        }

        /// One tier's rows grouped into units, in the position of each unit's first member.
        static func units(of items: [SupermuxOrderItem<ID>]) -> [Unit] {
            let fixedNames = Set(items.filter(\.isFixed).map(\.unit))
            var units: [Unit] = []
            var movingIndex: [String: Int] = [:]
            var previousFixedName: String?
            for item in items {
                if fixedNames.contains(item.unit) {
                    if previousFixedName == item.unit, let last = units.indices.last {
                        units[last].append(item)
                    } else {
                        units.append(Unit(item, isFixed: true))
                    }
                    previousFixedName = item.unit
                } else {
                    if let index = movingIndex[item.unit] {
                        units[index].append(item)
                    } else {
                        movingIndex[item.unit] = units.count
                        units.append(Unit(item, isFixed: false))
                    }
                    previousFixedName = nil
                }
            }
            return units
        }
    }
}

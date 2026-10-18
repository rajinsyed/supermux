internal import SupermuxMobileCore

/// The state of one ``SupermuxOrderCapture/plan(baseline:rows:hinted:programmatic:known:seed:)``
/// call, carried from tier to tier.
struct SupermuxOrderCapturePass<ID: Hashable & Sendable> {
    typealias Row = SupermuxOrderCaptureRow<ID>

    let baseIndex: [SupermuxOrderPosition<ID>: Int]
    /// Rows a reorder named: the only mirrors that may be sent.
    let hinted: Set<ID>
    /// The rows that count as movers: the hinted rows and every member of a
    /// hinted row's local group (a bump of one member moves the whole group).
    let movers: Set<ID>
    let programmatic: Set<ID>
    /// The window's first pass: the baseline is the keyed rows in key order.
    let isFirstPass: Bool
    var known: Set<String>
    let seed: String
    var plan = SupermuxOrderCapturePlan<ID>()

    private let orderKey = SupermuxOrderKey()

    init(
        baseIndex: [SupermuxOrderPosition<ID>: Int],
        hinted: Set<ID>,
        movers: Set<ID>,
        programmatic: Set<ID>,
        isFirstPass: Bool,
        known: Set<String>,
        seed: String
    ) {
        self.baseIndex = baseIndex
        self.hinted = hinted
        self.movers = movers
        self.programmatic = programmatic
        self.isFirstPass = isFirstPass
        self.known = known
        self.seed = seed
    }

    /// Plans one tier's rows, in tab order.
    mutating func capture(_ rows: [Row]) {
        let kept = keptRows(rows)
        let upperAnchors = upperAnchors(rows, kept: kept)
        var anchors = [SupermuxOrderSortKey?](repeating: nil, count: rows.count)
        var lower: SupermuxOrderSortKey?
        var minted: [Int] = []
        for (index, row) in rows.enumerated() {
            let upper = upperAnchors[index]
            if kept.contains(index), let sortKey = row.sortKey {
                anchors[index] = sortKey
                lower = Self.max(lower, sortKey)
                continue
            }
            if row.isMirror, !isSendable(row) { continue }
            if let sortKey = row.sortKey, Self.fits(sortKey, after: lower, before: upper) {
                anchors[index] = sortKey
                lower = sortKey
                continue
            }
            let key = orderKey.mint(
                after: lower?.key,
                before: upper?.key,
                known: Array(known.subtracting(row.validKey.map { [$0] } ?? [])),
                seed: seed
            )
            record(key, for: row)
            anchors[index] = row.sortKey(withKey: key)
            lower = anchors[index]
            if !row.isMirror { minted.append(index) }
        }
        rebalance(rows, minted: minted, anchors: &anchors)
    }

    /// The rows that kept their relative order since the baseline.
    private func keptRows(_ rows: [Row]) -> Set<Int> {
        let present = rows.indices.filter { baseIndex[rows[$0].position] != nil }
        let presentRows = present.map { rows[$0] }
        let kept = SupermuxWeightedLIS().indices(
            of: presentRows.map { baseIndex[$0.position] ?? 0 },
            weights: weights(presentRows)
        )
        return Set(kept.map { present[$0] })
    }

    /// A programmatic move must never look like the mover's neighbours moved
    /// (weight 0), and a mover is always the likelier one: any one other row
    /// outweighs every mover together, so a block moved at once never
    /// outvotes the fewer rows it jumped over. On a first pass any one own
    /// row outweighs every mirror together, so restored mirrors out of key
    /// order (their owner moved them meanwhile) never re-key this Mac's rows.
    private func weights(_ rows: [Row]) -> [Int] {
        let unmoved = rows.filter { movers.contains($0.id) }.count + 1
        let ownFactor = isFirstPass ? rows.filter(\.isMirror).count + 1 : 1
        return rows.map { row in
            if programmatic.contains(row.id) { return 0 }
            if movers.contains(row.id) { return 1 }
            return row.isMirror ? unmoved : unmoved * ownFactor
        }
    }

    /// For each row, the lowest sort key among the kept, keyed rows after it.
    private func upperAnchors(_ rows: [Row], kept: Set<Int>) -> [SupermuxOrderSortKey?] {
        var anchors = [SupermuxOrderSortKey?](repeating: nil, count: rows.count)
        var lowest: SupermuxOrderSortKey?
        for index in rows.indices.reversed() {
            anchors[index] = lowest
            if kept.contains(index), let sortKey = rows[index].sortKey {
                lowest = lowest.map { Swift.min($0, sortKey) } ?? sortKey
            }
        }
        return anchors
    }

    /// Whether a mirror's move is the user's, on this Mac, and may go to its owner.
    private func isSendable(_ row: Row) -> Bool {
        hinted.contains(row.id)
            && baseIndex[row.position] != nil
            && !programmatic.contains(row.id)
            && row.canSendToOwner
            && row.sortKey != nil
    }

    private mutating func record(_ key: String, for row: Row) {
        known.insert(key)
        guard key != row.validKey else { return }
        if row.isMirror {
            plan.mirrorKeys[row.id] = key
        } else {
            plan.ownKeys[row.id] = key
        }
    }

    /// Re-keys the run of own rows around each new own key that grew past
    /// ``SupermuxOrderKey/rebalanceLength``, between the nearest anchors outside the run.
    private mutating func rebalance(_ rows: [Row], minted: [Int], anchors: inout [SupermuxOrderSortKey?]) {
        var done = Set<Int>()
        for index in minted where !done.contains(index) {
            guard let key = anchors[index]?.key, key.utf8.count > SupermuxOrderKey.rebalanceLength else { continue }
            var start = index
            while start > 0, !rows[start - 1].isMirror { start -= 1 }
            var end = index
            while end < rows.count - 1, !rows[end + 1].isMirror { end += 1 }
            let run = Array(start...end)
            done.formUnion(run)
            let lower = anchors[..<start].last { $0 != nil }??.key
            let upper = anchors[(end + 1)...].first { $0 != nil }??.key
            let keys = orderKey.keys(between: lower, and: upper, count: run.count)
            guard keys.count == run.count else { continue }
            for (rowIndex, key) in zip(run, keys) {
                let row = rows[rowIndex]
                known.insert(key)
                plan.ownKeys[row.id] = key == row.validKey ? nil : key
                anchors[rowIndex] = row.sortKey(withKey: key)
            }
        }
    }

    private static func fits(_ sortKey: SupermuxOrderSortKey, after lower: SupermuxOrderSortKey?, before upper: SupermuxOrderSortKey?) -> Bool {
        (lower.map { $0 < sortKey } ?? true) && (upper.map { sortKey < $0 } ?? true)
    }

    private static func max(_ lhs: SupermuxOrderSortKey?, _ rhs: SupermuxOrderSortKey) -> SupermuxOrderSortKey {
        lhs.map { Swift.max($0, rhs) } ?? rhs
    }
}

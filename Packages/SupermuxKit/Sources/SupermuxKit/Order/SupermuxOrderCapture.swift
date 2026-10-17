internal import SupermuxMobileCore

/// Decides which order keys one window's tab change writes: own rows that
/// moved get a new key where they now sit (position → key), and a mirror the
/// user moved gets a key to send to its owner.
///
/// A pure function over plain rows; the Mac reconciler adapts its
/// `TabManager` state into ``SupermuxOrderCaptureRow`` values and stores or
/// sends the result. Each tier (pinned, unpinned) is planned on its own:
///
/// 1. The rows that kept their relative order since the baseline are found
///    with a weighted longest increasing subsequence (a programmatic move
///    weighs 0, a hinted row 1, any other row 2), so the rows left out are
///    the movers. A row whose tier changed counts as new.
/// 2. A kept, keyed row is an anchor. Every other own row keeps its key when
///    it still fits between the nearest anchors (the highest one before it,
///    the lowest kept one after it), else gets a new key there through
///    ``SupermuxOrderKey/mint(after:before:known:seed:)``. A mirror is keyed
///    only when it was hinted, was present at the baseline, was not moved
///    programmatically, and may be sent to its owner; any other mirror is
///    skipped and is not an anchor.
/// 3. When a new own key grows past ``SupermuxOrderKey/rebalanceLength``,
///    the run of own rows around it is re-keyed with short keys between the
///    nearest anchors outside it.
///
/// On the first pass of a window (no baseline) the baseline is every keyed
/// row in sort-key order and hints are ignored: the tabs are the truth, only
/// the minimal set of out-of-order own rows is re-keyed, and no mirror is sent.
///
/// ```swift
/// let plan = SupermuxOrderCapture().plan(
///     baseline: state.baseline, rows: rows, hinted: hints, programmatic: programmatic,
///     known: knownKeys(), seed: origin
/// )
/// state.baseline = rows.map(\.position)
/// ```
public struct SupermuxOrderCapture: Sendable {
    private let orderKey = SupermuxOrderKey()

    /// Creates the planner.
    public init() {}

    /// The keys a window's tab change writes.
    ///
    /// - Parameters:
    ///   - baseline: Every row's position at the end of the previous pass, or
    ///     `nil` on the window's first pass.
    ///   - rows: The window's rows in current tab order. Leave out rows that
    ///     are neither a bound mirror nor an own row (a mirror still binding).
    ///   - hinted: Rows a reorder notification named since the last pass.
    ///   - programmatic: Rows a fork programmatic move placed since the last pass.
    ///   - known: Every key the Mac knows (its store, every record, every
    ///     pending key). The rows' own keys are added, and invalid keys ignored.
    ///   - seed: This Mac's origin, for a first key when nothing is known.
    /// - Returns: The new keys; empty when nothing moved.
    public func plan<ID>(
        baseline: [SupermuxOrderPosition<ID>]?,
        rows: [SupermuxOrderCaptureRow<ID>],
        hinted: Set<ID>,
        programmatic: Set<ID>,
        known: [String],
        seed: String
    ) -> SupermuxOrderCapturePlan<ID> {
        let positions = baseline ?? firstPassBaseline(rows)
        let baseIndex = Dictionary(
            positions.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var pass = SupermuxOrderCapturePass<ID>(
            baseIndex: baseIndex,
            hinted: baseline == nil ? [] : hinted,
            programmatic: programmatic,
            known: Set(known.filter(orderKey.isValid) + rows.compactMap(\.validKey)),
            seed: seed
        )
        for tier in Set(rows.map(\.tier)).sorted() {
            pass.capture(rows.filter { $0.tier == tier })
        }
        return pass.plan
    }

    /// The first pass's baseline: every keyed row, in sort-key order.
    private func firstPassBaseline<ID>(_ rows: [SupermuxOrderCaptureRow<ID>]) -> [SupermuxOrderPosition<ID>] {
        rows.compactMap { row in row.sortKey.map { (sortKey: $0, position: row.position) } }
            .sorted { $0.sortKey < $1.sortKey }
            .map(\.position)
    }
}

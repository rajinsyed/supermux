import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// The Mac capture planner: which own rows get a new order key, and which
/// moved mirrors ask their owner for one, after a window's tabs changed.
///
/// Ways it could fail, written before the code (design §4 C, plus the first
/// run of §3.7 and the rebalance of #2):
/// 1. (#12) A reorder entry point that posts no hint is missed: capture must
///    diff the tabs against the baseline, hint or not.
/// 2. (#13) Apply's own moves, or capture's own keys, are captured again
///    (echo): a plan over its own output must be empty, and an unhinted
///    mirror move (apply suppresses hints) is never sent.
/// 3. (#14) A fork programmatic move (sibling placement, mirrored pin) is
///    taken for a user move: it must neither be sent to the owner nor blame
///    the rows around it.
/// 4. (#15) Hover steps accumulated between passes write more than one key
///    for the one moved row.
/// 5. (#16) An adjacent swap blames the wrong row: the hinted row is the mover.
/// 6. (#17) A side effect of group normalization (several rows displaced at
///    once) leaves keys that disagree with the tabs.
/// 7. (#19) A session restore, or a first pass whose stored keys already
///    agree with the tabs, writes keys.
/// 8. (#20) Tabs older than the keys (a crash before the autosave) re-key
///    more own rows than the minimal out-of-order set.
/// 9. (#21) A cross-window drop is moved away: a new row keeps its key only
///    if it fits where it landed, else gets a key right there.
/// 10. (#22) Out-of-order anchors (a record key changed, apply not run yet)
///     give a key that disagrees with the neighbours or traps: the key goes
///     right after the predecessor.
/// 11. (#23) A mirror whose pin differs from its record (a local pin) is sent.
/// 12. (#24) An unkeyed mirror is used as an anchor, or is sent.
/// 13. (#25) A row whose tier changed keeps a key from the other tier.
/// 14. (#26) An own row with no key stays unkeyed because it did not move.
/// 15. (#3) An invalid key counts as a key: it must count as none.
/// 16. (§3.7, #33) The first pass after an upgrade reorders this Mac's rows,
///     ignores the keyed mirrors between them, zippers into the keys of
///     other windows, or sends a mirror to its owner.
/// 17. (#2) A minted key that grows past the rebalance length is left long,
///     or the rebalance touches a mirror or breaks the order.
///
/// Not covered here (not pure): #18 (the pass hops past `willSet`) and the
/// mouse-button gate of #15 belong to the reconciler and its E2E steps.
@Suite struct SupermuxOrderCaptureTests {
    private typealias Row = SupermuxOrderCaptureRow<String>
    private typealias Plan = SupermuxOrderCapturePlan<String>

    private let capture = SupermuxOrderCapture()
    private let seed = "mac:0f7c2c7e-1d51-4d0e-9d7c-2c9b2a4b7e11@default"

    // MARK: Helpers

    private func own(_ id: String, _ key: String?, pinned: Bool = false) -> Row {
        .own(id: id, tier: pinned ? 0 : 1, key: key, canonicalID: id)
    }

    private func mirror(_ id: String, _ key: String?, pinned: Bool = false, canSend: Bool = true) -> Row {
        .mirror(id: id, tier: pinned ? 0 : 1, key: key, canonicalID: id, canSendToOwner: canSend)
    }

    private func plan(
        baseline: [Row]?,
        rows: [Row],
        hinted: Set<String> = [],
        programmatic: Set<String> = [],
        known: [String] = []
    ) -> Plan {
        capture.plan(
            baseline: baseline?.map(\.position),
            rows: rows,
            hinted: hinted,
            programmatic: programmatic,
            known: known,
            seed: seed
        )
    }

    /// The rows with the plan's keys written in (a mirror's key as its pending key).
    private func applying(_ plan: Plan, to rows: [Row]) -> [Row] {
        rows.map { row in
            let key = plan.ownKeys[row.id] ?? plan.mirrorKeys[row.id] ?? row.key
            return row.isMirror
                ? .mirror(id: row.id, tier: row.tier, key: key, canonicalID: row.canonicalID, canSendToOwner: row.canSendToOwner)
                : .own(id: row.id, tier: row.tier, key: key, canonicalID: row.canonicalID)
        }
    }

    /// Whether the keyed rows of every tier sort in tab order.
    private func isAscending(_ rows: [Row]) -> Bool {
        Set(rows.map(\.tier)).allSatisfy { tier in
            let sortKeys = rows.filter { $0.tier == tier }.compactMap(\.sortKey)
            return zip(sortKeys, sortKeys.dropFirst()).allSatisfy { $0 < $1 }
        }
    }

    private func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private func isBetween(_ key: String?, _ lower: String, _ upper: String) -> Bool {
        guard let key else { return false }
        return precedes(lower, key) && precedes(key, upper)
    }

    // MARK: First pass (7, 8, 16)

    @Test func aFirstPassWithAnEmptyStoreKeysEveryOwnRowInTabOrder() {
        let rows = [own("A", nil), own("B", nil), own("C", nil)]
        let result = plan(baseline: nil, rows: rows)
        #expect(Set(result.ownKeys.keys) == ["A", "B", "C"])
        #expect(result.mirrorKeys.isEmpty)
        #expect(isAscending(applying(result, to: rows)))
    }

    @Test func aFirstPassKeysOwnRowsBetweenTheKeyedMirrorsAroundThem() {
        let rows = [mirror("M1", "a0"), own("O1", nil), mirror("M2", "a2"), own("O2", nil)]
        let result = plan(baseline: nil, rows: rows)
        #expect(isBetween(result.ownKeys["O1"], "a0", "a2"))
        #expect(result.ownKeys["O2"].map { precedes("a2", $0) } == true)
        #expect(result.mirrorKeys.isEmpty)
    }

    @Test func aFirstPassWithNoKeyedNeighbourStartsAfterEveryKnownKey() {
        // Another window already holds "a5" and "b00": this one starts a block after them.
        let rows = [own("A", nil), own("B", nil)]
        let result = plan(baseline: nil, rows: rows, known: ["a5", "b00"])
        #expect(result.ownKeys["A"].map { precedes("b00", $0) } == true)
        #expect(isAscending(applying(result, to: rows)))
    }

    @Test func aFirstPassWhoseStoredKeysAgreeWithTheTabsWritesNothing() {
        let rows = [own("A", "a0"), mirror("M", "a0V"), own("B", "a1"), own("C", "a2")]
        #expect(plan(baseline: nil, rows: rows).isEmpty)
    }

    @Test func aFirstPassReKeysOnlyTheMinimalOutOfOrderRows() {
        let rows = [own("A", "a0"), own("C", "a2"), own("B", "a1"), own("D", "a3")]
        let result = plan(baseline: nil, rows: rows)
        #expect(result.ownKeys.count == 1)
        #expect(isAscending(applying(result, to: rows)))
    }

    @Test func aFirstPassNeverSendsAMirror() {
        // Out of key order and hinted, but nothing on this Mac moved it since a pass.
        let rows = [mirror("M", "a2"), own("A", "a0"), own("B", "a1")]
        let result = plan(baseline: nil, rows: rows, hinted: ["M"])
        #expect(result.mirrorKeys.isEmpty)
        #expect(result.ownKeys.isEmpty)
    }

    // MARK: Moves of own rows (1, 2, 4, 5, 6)

    @Test func aMoveWithoutAHintIsStillCaptured() {
        let before = [own("A", "a0"), own("B", "a1"), own("C", "a2")]
        let after = [before[1], before[2], before[0]]
        let result = plan(baseline: before, rows: after)
        #expect(Set(result.ownKeys.keys) == ["A"])
        #expect(isAscending(applying(result, to: after)))
    }

    @Test func aHintedSwapReKeysTheHintedRow() {
        let before = [own("A", "a0"), own("B", "a1")]
        let after = [before[1], before[0]]

        let movedB = plan(baseline: before, rows: after, hinted: ["B"])
        #expect(Set(movedB.ownKeys.keys) == ["B"])
        #expect(movedB.ownKeys["B"].map { precedes($0, "a0") } == true)

        let movedA = plan(baseline: before, rows: after, hinted: ["A"])
        #expect(Set(movedA.ownKeys.keys) == ["A"])
        #expect(movedA.ownKeys["A"].map { precedes("a1", $0) } == true)
    }

    @Test func hoverStepsBetweenPassesWriteOneKeyForTheMovedRow() {
        let before = [own("A", "a0"), own("B", "a1"), own("C", "a2"), own("D", "a3")]
        // A hovered past B, then past C, before the drop; the hints accumulated.
        let after = [before[1], before[2], before[0], before[3]]
        let result = plan(baseline: before, rows: after, hinted: ["A"])
        #expect(Set(result.ownKeys.keys) == ["A"])
        #expect(isBetween(result.ownKeys["A"], "a2", "a3"))
    }

    @Test func aGroupMoveThatDisplacesSeveralRowsLeavesKeysInTabOrder() {
        let before = [own("A", "a0"), own("G1", "a1"), own("G2", "a2"), mirror("M", "a2V"), own("B", "a3")]
        let after = [before[1], before[2], before[0], before[3], before[4]]
        let result = plan(baseline: before, rows: after, hinted: ["G1", "G2"])
        #expect(result.ownKeys.count <= 2)
        #expect(result.mirrorKeys.isEmpty)
        #expect(isAscending(applying(result, to: after)))
    }

    @Test func captureIsIdempotentOnItsOwnOutput() {
        let before = [own("A", "a0"), mirror("M", "a1"), own("B", "a2"), own("C", "a3")]
        let after = [before[3], before[0], before[1], before[2], own("N", nil)]
        let first = plan(baseline: before, rows: after, hinted: ["C"])
        #expect(!first.isEmpty)

        let keyed = applying(first, to: after)
        #expect(isAscending(keyed))
        #expect(plan(baseline: keyed, rows: keyed).isEmpty)
    }

    // MARK: Mirrors (2, 3, 11, 12)

    @Test func aHintedMirrorMoveIsSentToItsOwner() {
        let before = [own("A", "a0"), mirror("M", "a1"), own("B", "a2")]
        let after = [before[1], before[0], before[2]]
        let result = plan(baseline: before, rows: after, hinted: ["M"])
        #expect(result.ownKeys.isEmpty)
        #expect(Set(result.mirrorKeys.keys) == ["M"])
        #expect(result.mirrorKeys["M"].map { precedes($0, "a0") } == true)
    }

    @Test func anUnhintedMirrorMoveIsNeverSent() {
        let before = [own("A", "a0"), mirror("M", "a1"), own("B", "a2")]
        let after = [before[1], before[0], before[2]]
        #expect(plan(baseline: before, rows: after).isEmpty)
    }

    @Test func aProgrammaticMirrorMoveIsNeverSentEvenWhenHinted() {
        let before = [own("A", "a0"), mirror("M", "a1"), own("B", "a2")]
        let after = [before[1], before[0], before[2]]
        #expect(plan(baseline: before, rows: after, hinted: ["M"], programmatic: ["M"]).isEmpty)
    }

    @Test func aProgrammaticPlacementDoesNotBlameTheRowsAroundIt() {
        let before = [own("A", "a0"), own("B", "a1"), mirror("M", "a5")]
        let after = [before[0], before[2], before[1]]
        #expect(plan(baseline: before, rows: after, programmatic: ["M"]).isEmpty)
    }

    @Test func aMirrorWithALocalPinIsNeverSent() {
        let before = [own("A", "a0"), mirror("M", "a1", canSend: false), own("B", "a2")]
        let after = [before[1], before[0], before[2]]
        #expect(plan(baseline: before, rows: after, hinted: ["M"]).isEmpty)
    }

    @Test func anUnkeyedMirrorIsNeverSent() {
        let before = [own("A", "a1"), mirror("U", nil), own("B", "a3")]
        let after = [before[1], before[0], before[2]]
        #expect(plan(baseline: before, rows: after, hinted: ["U"]).isEmpty)
    }

    @Test func anUnkeyedMirrorIsNeverAnAnchor() {
        let before = [own("A", "a1"), mirror("U", nil), own("B", "a3")]
        let after = [before[0], before[1], own("N", nil), before[2]]
        let result = plan(baseline: before, rows: after)
        #expect(Set(result.ownKeys.keys) == ["N"])
        #expect(isBetween(result.ownKeys["N"], "a1", "a3"))
    }

    @Test func aHintedMirrorWhoseKeyStillFitsIsNotResent() {
        // M moved past an unkeyed mirror only: its key still sits between its keyed neighbours.
        let before = [own("A", "a0"), mirror("U", nil), mirror("M", "a1"), own("B", "a2")]
        let after = [before[0], before[2], before[1], before[3]]
        #expect(plan(baseline: before, rows: after, hinted: ["M"]).isEmpty)
    }

    // MARK: New rows and tiers (9, 13, 14, 15)

    @Test func aDroppedRowKeepsAKeyThatStillFits() {
        let before = [own("A", "a0"), own("B", "a2")]
        let after = [before[0], own("X", "a1"), before[1]]
        #expect(plan(baseline: before, rows: after).isEmpty)
    }

    @Test func aDroppedRowWhoseKeyDoesNotFitGetsAKeyWhereItLanded() {
        let before = [own("A", "a0"), own("B", "a2")]
        let after = [before[0], own("X", "a5"), before[1]]
        let result = plan(baseline: before, rows: after)
        #expect(Set(result.ownKeys.keys) == ["X"])
        #expect(isBetween(result.ownKeys["X"], "a0", "a2"))
    }

    @Test func aRowPinnedBelowAHigherKeyIsReKeyedInItsNewTier() {
        let before = [own("P", "a5", pinned: true), own("X", "a1"), own("Y", "a3")]
        let after = [before[0], own("X", "a1", pinned: true), before[2]]
        let result = plan(baseline: before, rows: after)
        #expect(Set(result.ownKeys.keys) == ["X"])
        #expect(result.ownKeys["X"].map { precedes("a5", $0) } == true)
    }

    @Test func aRowPinnedWhereItsKeyFitsKeepsIt() {
        let before = [own("P", "a5", pinned: true), own("X", "a1"), own("Y", "a3")]
        let after = [own("X", "a1", pinned: true), before[0], before[2]]
        #expect(plan(baseline: before, rows: after).isEmpty)
    }

    @Test func anOwnRowWithoutAKeyIsKeyedEvenWhenItDidNotMove() {
        let rows = [own("A", "a0"), own("B", nil), own("C", "a2")]
        let result = plan(baseline: rows, rows: rows)
        #expect(Set(result.ownKeys.keys) == ["B"])
        #expect(isBetween(result.ownKeys["B"], "a0", "a2"))
    }

    @Test func anInvalidKeyCountsAsNoKey() {
        let rows = [own("A", "a0"), own("B", "not a key"), own("C", "a2")]
        let result = plan(baseline: rows, rows: rows)
        #expect(Set(result.ownKeys.keys) == ["B"])
        #expect(isBetween(result.ownKeys["B"], "a0", "a2"))

        let before = [own("D", "a0"), mirror("M", "zz!"), own("E", "a2")]
        let after = [before[1], before[0], before[2]]
        #expect(plan(baseline: before, rows: after, hinted: ["M"]).isEmpty)
    }

    // MARK: Out-of-order anchors (10)

    @Test func outOfOrderAnchorsPlaceTheRowRightAfterItsPredecessor() {
        // M2's record key changed to below M1's, and apply has not moved it yet.
        let before = [mirror("M1", "a5"), mirror("M2", "a6")]
        let after = [mirror("M1", "a5"), own("N", nil), mirror("M2", "a1")]
        let result = plan(baseline: before, rows: after, known: ["a7"])
        #expect(Set(result.ownKeys.keys) == ["N"])
        #expect(isBetween(result.ownKeys["N"], "a5", "a7"))
        #expect(result.mirrorKeys.isEmpty)
    }

    // MARK: Rebalance (17)

    @Test func aLongMintedKeyReKeysTheOwnRunOnly() {
        let crowded = "a0" + String(repeating: "0", count: 64) + "1"
        let before = [mirror("M1", "Zz"), own("X", "a0"), own("Y", crowded), mirror("M2", "b00")]
        let after = [before[0], before[1], own("N", nil), before[2], before[3]]
        let result = plan(baseline: before, rows: after)

        #expect(result.ownKeys["N"] != nil)
        #expect(Set(result.ownKeys.keys).isSubset(of: ["X", "N", "Y"]))
        #expect(result.mirrorKeys.isEmpty)
        let keyed = applying(result, to: after)
        #expect(isAscending(keyed))
        #expect(keyed.filter { !$0.isMirror }.allSatisfy { ($0.key?.count ?? .max) <= SupermuxOrderKey.rebalanceLength })
    }
}

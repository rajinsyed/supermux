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
/// 18. (#16, review R1) A move of several rows at once (a group drag, a
///     multi-select drag) outvotes the fewer rows it jumped over, so the drop
///     is undone and the jumped-over rows are re-keyed: no number of hinted
///     rows may outweigh one unhinted row.
/// 19. (#16, review R1) A notification bump hints one member of a group but
///     moves the whole group: every member of a hinted row's local group
///     counts as a mover, yet only a row the reorder named is ever sent.
/// 20. (§3.2.3, review R2) On a first pass (a restart) restored mirrors out of
///     key order outvote this Mac's own rows, which are then re-keyed: no
///     number of mirrors may outweigh one own row.
/// 21. (#16, re-review RR1) Inside a hinted row's local group the widened
///     mates outvote the row the user named, so a move past a mirror mate is
///     never keyed: a mate always outweighs every hinted row together, and
///     any other row every mover together.
/// 22. (#22, re-review RR2) A kept mirror whose key is out of order with the
///     kept own rows around it (a locally grouped mirror its owner moved,
///     which apply never places) bounds a moved own row, which then sorts
///     after the mirror elsewhere: such a mirror is not an anchor.
///
/// Not covered here (not pure): #18 (the pass hops past `willSet`) and the
/// mouse-button gate of #15 belong to the reconciler and its E2E steps.
@Suite struct SupermuxOrderCaptureTests {
    private typealias Row = SupermuxOrderCaptureRow<String>
    private typealias Plan = SupermuxOrderCapturePlan<String>

    private let capture = SupermuxOrderCapture()
    private let seed = "mac:0f7c2c7e-1d51-4d0e-9d7c-2c9b2a4b7e11@default"

    // MARK: Helpers

    private func own(_ id: String, _ key: String?, pinned: Bool = false, group: String? = nil) -> Row {
        .own(id: id, tier: pinned ? 0 : 1, key: key, canonicalID: id, group: group)
    }

    private func mirror(_ id: String, _ key: String?, pinned: Bool = false, canSend: Bool = true, group: String? = nil) -> Row {
        .mirror(id: id, tier: pinned ? 0 : 1, key: key, canonicalID: id, canSendToOwner: canSend, group: group)
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
                ? .mirror(id: row.id, tier: row.tier, key: key, canonicalID: row.canonicalID,
                          canSendToOwner: row.canSendToOwner, group: row.group)
                : .own(id: row.id, tier: row.tier, key: key, canonicalID: row.canonicalID, group: row.group)
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

    @Test func aFirstPassAfterARestartNeverReKeysOwnRowsForStaleMirrors() {
        // Quit with [M1, M2, M3, O1]; while this Mac was off, the owner moved
        // M1..M3 below O1 (keys a4..a6). The restored mirrors are now out of
        // key order, and the own row must keep its key (apply moves the mirrors).
        let restored = [mirror("M1", "a4"), mirror("M2", "a5"), mirror("M3", "a6"), own("O1", "a3")]
        #expect(plan(baseline: nil, rows: restored).isEmpty)

        // A mirror kept in a local group is never moved by apply, so it stays
        // out of key order across restarts; it must not re-key the own row either.
        let grouped = [own("O1", "a1"), mirror("M1", "a0", group: "G"), mirror("M2", "a0V", group: "G")]
        #expect(plan(baseline: nil, rows: grouped).isEmpty)
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

    @Test func aGroupDraggedAboveAMirrorKeepsItsDrop() {
        // A group header drag hints every member.
        let before = [own("X", "a0"), mirror("B", "a1"), own("G1", "a2", group: "G"), own("G2", "a3", group: "G")]
        let after = [before[0], before[2], before[3], before[1]]
        let result = plan(baseline: before, rows: after, hinted: ["G1", "G2"])
        #expect(Set(result.ownKeys.keys) == ["G1", "G2"])
        #expect(isBetween(result.ownKeys["G1"], "a0", "a1"))
        #expect(isBetween(result.ownKeys["G2"], "a0", "a1"))
        #expect(result.mirrorKeys.isEmpty)
        #expect(isAscending(applying(result, to: after)))
    }

    @Test func aMultiSelectDragAboveAMirrorKeepsItsDrop() {
        let before = [mirror("M", "a0"), own("R1", "a1"), own("R2", "a2"), own("R3", "a3")]
        let after = [before[1], before[2], before[3], before[0]]
        let result = plan(baseline: before, rows: after, hinted: ["R1", "R2", "R3"])
        #expect(Set(result.ownKeys.keys) == ["R1", "R2", "R3"])
        #expect(result.ownKeys.values.allSatisfy { precedes($0, "a0") })
        #expect(result.mirrorKeys.isEmpty)
        #expect(isAscending(applying(result, to: after)))
    }

    @Test func aNotificationBumpOfOneMemberMovesTheWholeGroup() {
        // The bump moves the group to the top but names only the bumped member.
        let before = [
            own("R1", "a0"), mirror("M", "a1"),
            own("G1", "a2", group: "G"), own("G2", "a3", group: "G"), own("G3", "a4", group: "G"),
        ]
        let after = [before[2], before[3], before[4], before[0], before[1]]
        let result = plan(baseline: before, rows: after, hinted: ["G2"])
        #expect(Set(result.ownKeys.keys) == ["G1", "G2", "G3"])
        #expect(result.ownKeys.values.allSatisfy { precedes($0, "a0") })
        #expect(result.mirrorKeys.isEmpty)
        #expect(isAscending(applying(result, to: after)))
    }

    @Test func aMoveInsideAGroupNeverSendsAnUnmovedMirrorMember() {
        // G2 dragged above the group's mirror member GM: the group's members all
        // count as movers, but GM was not moved by the user and is never sent;
        // G2, the row the user named, is the one re-keyed into place.
        let before = [own("G1", "a0", group: "G"), mirror("GM", "a1", group: "G"), own("G2", "a2", group: "G")]
        let after = [before[0], before[2], before[1]]
        let result = plan(baseline: before, rows: after, hinted: ["G2"])
        #expect(result.mirrorKeys.isEmpty)
        #expect(Set(result.ownKeys.keys) == ["G2"])
        #expect(isBetween(result.ownKeys["G2"], "a0", "a1"))
        #expect(isAscending(applying(result, to: after)))

        // The same move in a group a mirror anchors, with a row after the group.
        let anchored = [
            mirror("MA", "a0", group: "G"), mirror("M2", "a1", group: "G"), own("O", "a2", group: "G"), own("X", "a3"),
        ]
        let moved = [anchored[0], anchored[2], anchored[1], anchored[3]]
        let anchoredResult = plan(baseline: anchored, rows: moved, hinted: ["O"])
        #expect(anchoredResult.mirrorKeys.isEmpty)
        #expect(Set(anchoredResult.ownKeys.keys) == ["O"])
        #expect(isBetween(anchoredResult.ownKeys["O"], "a0", "a1"))
        #expect(isAscending(applying(anchoredResult, to: moved)))
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
        // Without a hint this is ambiguous: A may have moved down past M (a missed
        // entry point, 1). Keeping the tabs as shown re-keys A, never sends M.
        let result = plan(baseline: before, rows: after)
        #expect(result.mirrorKeys.isEmpty)
        #expect(isAscending(applying(result, to: after)))
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

    @Test func aKeptMirrorOutOfKeyOrderNeverBoundsOwnRows() {
        // M sits in a local group at the top, so apply never moves it, but its
        // owner moved it to the bottom (a5). O3 dragged above O1 must still get
        // a key before O1's, not one after M's.
        let before = [mirror("M", "a5", group: "G"), own("O1", "a1"), own("O2", "a2"), own("O3", "a3")]
        let after = [before[0], before[3], before[1], before[2]]
        let result = plan(baseline: before, rows: after, hinted: ["O3"])
        #expect(result.mirrorKeys.isEmpty)
        #expect(Set(result.ownKeys.keys) == ["O3"])
        #expect(result.ownKeys["O3"].map { precedes($0, "a1") } == true)

        // O1 moved below O2: its key goes between O2's and O3's.
        let below = [before[0], before[2], before[1], before[3]]
        let belowResult = plan(baseline: before, rows: below, hinted: ["O1"])
        #expect(Set(belowResult.ownKeys.keys) == ["O1"])
        #expect(isBetween(belowResult.ownKeys["O1"], "a2", "a3"))
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

@testable import SupermuxMobileCore
import Testing

/// The one comparator and arrangement every Mac and the phone use to show
/// workspaces in the shared order.
///
/// Ways it could fail, written before the code (design §4):
/// 1. (#4) Two owners mint equal keys at once, and devices order the pair
///    differently: equal keys must break on the canonical id, then `tieRank`.
/// 2. (#5) Loopback twins (an own row and its mirror share a key and an id)
///    swap from pass to pass: own (`tieRank` 0) must sort before mirror.
/// 3. (#9) The Mac's canonical id and the phone's differ in case, so their
///    tie-breaks differ.
/// 4. (#27) Mac apply moves its own rows: fixed rows keep their order even
///    when their keys disagree with it.
/// 5. (#28) Apply drops a mirror inside a local group, and the group
///    normalization moves it back every pass: moving rows land only at unit
///    boundaries.
/// 6. (#32, #54) A remote group (or a phone group) is split by rows that sort
///    between its members, leaving stray members: a unit moves as one block,
///    ranked by its lowest key.
/// 7. (#47) Keyed and unkeyed rows mix: keyed rows first in their tier,
///    unkeyed after them in incoming order; a fixed row with no key stays
///    where it is and places nothing.
/// 8. Tiers mix: a pinned row sorts among unpinned ones by key.
/// 9. A unit with both fixed and moving members is half moved, splitting it.
/// 10. Apply is not stable on its own output, so the reconciler re-issues an
///     order every pass (echo, #29).
@Suite struct SupermuxOrderArrangementTests {
    private let arrangement = SupermuxOrderArrangement()

    // MARK: Comparator (1, 2, 3)

    @Test func keysCompareInByteOrder() {
        let ordered = ["A000000000000000000000000000V", "Xzzz", "Zz", "a0", "a0V", "a1", "b00"]
        let sortKeys = ordered.map { SupermuxOrderSortKey(key: $0, canonicalID: "X", tieRank: 0) }
        #expect(sortKeys.shuffled().sorted() == sortKeys)
    }

    @Test func equalKeysBreakOnTheCanonicalIDThenTheTieRank() {
        let a = SupermuxOrderSortKey(key: "a1", canonicalID: "AAAA", tieRank: 1)
        let b = SupermuxOrderSortKey(key: "a1", canonicalID: "BBBB", tieRank: 0)
        let own = SupermuxOrderSortKey(key: "a1", canonicalID: "BBBB", tieRank: 0)
        let mirror = SupermuxOrderSortKey(key: "a1", canonicalID: "BBBB", tieRank: 1)
        #expect(a < b && !(b < a))
        #expect(own < mirror && !(mirror < own))
        #expect(SupermuxOrderSortKey(key: "a0", canonicalID: "ZZZZ", tieRank: 1) < a)
    }

    @Test func theCanonicalIDIgnoresCase() {
        let mac = SupermuxOrderSortKey(key: "a1", canonicalID: "7a1c1e4b-5d0e", tieRank: 0)
        let phone = SupermuxOrderSortKey(key: "a1", canonicalID: "7A1C1E4B-5D0E", tieRank: 0)
        #expect(mac == phone)
        #expect(mac.canonicalID == "7A1C1E4B-5D0E")
    }

    @Test func twoOwnersWithEqualKeysArrangeTheSameWayInAnyInputOrder() {
        let x = item("x", key: "a1", canonical: "BBBB")
        let y = item("y", key: "a1", canonical: "AAAA")
        #expect(arrangement.arrange([x, y]) == ["y", "x"])
        #expect(arrangement.arrange([y, x]) == ["y", "x"])
    }

    // MARK: Phone (all rows move) (6, 7, 8)

    @Test func nothingToArrangeIsEmpty() {
        #expect(arrangement.arrange([SupermuxOrderItem<String>]()).isEmpty)
    }

    @Test func unkeyedRowsKeepTheirOrderWithPinnedRowsFirst() {
        let rows = [item("u1", key: nil), item("p1", tier: 0, key: nil), item("u2", key: nil), item("p2", tier: 0, key: nil)]
        #expect(arrangement.arrange(rows) == ["p1", "p2", "u1", "u2"])
    }

    @Test func thePhoneInterleavesMacsByKeyAndPutsUnkeyedRowsLast() {
        let rows = [
            item("mac1-a", key: "a2"),
            item("mac1-old", key: nil),
            item("mac1-b", key: "a5"),
            item("mac2-a", key: "a3"),
            item("mac2-old", key: nil),
        ]
        #expect(arrangement.arrange(rows) == ["mac1-a", "mac2-a", "mac1-b", "mac1-old", "mac2-old"])
    }

    @Test func tiersNeverMix() {
        let rows = [
            item("unpinned-low", key: "Zz"),
            item("pinned-high", tier: 0, key: "b00"),
            item("pinned-low", tier: 0, key: "a0"),
            item("unpinned-high", key: "a5"),
        ]
        #expect(arrangement.arrange(rows) == ["pinned-low", "pinned-high", "unpinned-low", "unpinned-high"])
    }

    @Test func aGroupIsOneUnitRankedByItsLowestKey() {
        let rows = [
            item("g-late", key: "a9", unit: "g:1/1"),
            item("loose", key: "a3"),
            item("g-early", key: "a1", unit: "g:1/1"),
            item("g-old", key: nil, unit: "g:1/1"),
        ]
        #expect(arrangement.arrange(rows) == ["g-early", "g-late", "g-old", "loose"])
    }

    // MARK: Mac apply (own rows fixed, keyed mirrors move) (2, 4, 5, 6, 7, 9, 10)

    @Test func ownRowsNeverMove() {
        let rows = [
            item("w1", key: "a5", fixed: true),
            item("w2", key: "a1", fixed: true),
            item("w3", key: nil, fixed: true),
        ]
        #expect(arrangement.arrange(rows) == ["w1", "w2", "w3"])
    }

    @Test func eachMirrorLandsRightAfterItsSource() {
        let rows = [
            item("M3", key: "a3", canonical: "W3", tieRank: 1),
            item("W1", key: "a1", fixed: true),
            item("W2", key: "a2", fixed: true),
            item("M1", key: "a1", canonical: "W1", tieRank: 1),
            item("W3", key: "a3", fixed: true),
            item("M2", key: "a2", canonical: "W2", tieRank: 1),
        ]
        #expect(arrangement.arrange(rows) == ["W1", "M1", "W2", "M2", "W3", "M3"])
    }

    @Test func aMirrorNeverLandsInsideALocalGroup() {
        let rows = [
            item("g1", key: "a1", unit: "g:G", fixed: true),
            item("g2", key: "a5", unit: "g:G", fixed: true),
            item("w3", key: "a6", fixed: true),
            item("m", key: "a3"),
        ]
        #expect(arrangement.arrange(rows) == ["g1", "g2", "m", "w3"])
    }

    @Test func membersOfAFixedUnitKeepTheirOrder() {
        let rows = [
            item("g2", key: "a5", unit: "g:G", fixed: true),
            item("g1", key: "a1", unit: "g:G", fixed: true),
            item("m", key: "a0"),
        ]
        #expect(arrangement.arrange(rows) == ["m", "g2", "g1"])
    }

    @Test func aRemoteGroupMovesTogether() {
        let rows = [
            item("w1", key: "a1", fixed: true),
            item("r2", key: "a4", canonical: "R2", tieRank: 1, unit: "r:mac/G/1"),
            item("x", key: "a3", canonical: "X", tieRank: 1),
            item("w9", key: "a9", fixed: true),
            item("r1", key: "a2", canonical: "R1", tieRank: 1, unit: "r:mac/G/1"),
        ]
        #expect(arrangement.arrange(rows) == ["w1", "r1", "r2", "x", "w9"])
    }

    @Test func aFixedRowWithNoKeyStaysAndPlacesNothing() {
        let rows = [
            item("w1", key: "a1", fixed: true),
            item("old", key: nil, fixed: true),
            item("w5", key: "a5", fixed: true),
            item("m3", key: "a3"),
            item("m0", key: "a0"),
        ]
        #expect(arrangement.arrange(rows) == ["m0", "w1", "old", "m3", "w5"])
    }

    @Test func aMovingRowWithNoKeyGoesLast() {
        let rows = [
            item("unkeyed", key: nil),
            item("w1", key: "a1", fixed: true),
            item("late", key: "a9"),
            item("w3", key: "a3", fixed: true),
            item("m2", key: "a2"),
        ]
        #expect(arrangement.arrange(rows) == ["w1", "m2", "w3", "late", "unkeyed"])
    }

    @Test func aUnitWithAFixedMemberIsFixed() {
        let rows = [
            item("r1", key: "a9", unit: "r:mac/G/1"),
            item("w1", key: "a1", fixed: true),
            item("r2", key: nil, unit: "r:mac/G/1", fixed: true),
        ]
        #expect(arrangement.arrange(rows) == ["r1", "w1", "r2"])
    }

    @Test func applyIsStableOnItsOwnOutput() {
        let rows = [
            item("M2", key: "a2", canonical: "W2", tieRank: 1),
            item("g1", key: "a1", unit: "g:G", fixed: true),
            item("g2", key: "a4", unit: "g:G", fixed: true),
            item("W2", key: "a2", fixed: true),
            item("old", key: nil, fixed: true),
            item("r1", key: "a3", canonical: "R1", tieRank: 1, unit: "r:mac/G/1"),
            item("p", tier: 0, key: "a8", fixed: true),
            item("r2", key: "a0", canonical: "R2", tieRank: 1, unit: "r:mac/G/1"),
        ]
        let once = arrangement.arrange(rows)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let twice = arrangement.arrange(once.compactMap { byID[$0] })
        #expect(twice == once)
        #expect(once.first == "p")
    }

    // MARK: Helpers

    private func item(
        _ id: String,
        tier: Int = 1,
        key: String?,
        canonical: String? = nil,
        tieRank: Int = 0,
        unit: String? = nil,
        fixed: Bool = false
    ) -> SupermuxOrderItem<String> {
        SupermuxOrderItem(
            id: id,
            tier: tier,
            sortKey: key.map { SupermuxOrderSortKey(key: $0, canonicalID: canonical ?? id, tieRank: tieRank) },
            unit: unit ?? id,
            isFixed: fixed
        )
    }
}

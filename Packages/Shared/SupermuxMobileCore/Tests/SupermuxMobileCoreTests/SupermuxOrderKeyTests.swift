import Foundation
@testable import SupermuxMobileCore
import Testing

/// The fractional order key every Mac and the phone use to place a workspace.
///
/// Ways the key algebra could fail, written before the code (design §4 A):
/// 1. (#1) ``SupermuxOrderKey/between(_:_:)`` traps on equal keys or on
///    lower ≥ upper (the phone's equal-key neighbours, loopback twins). It must
///    return `nil`, and ``SupermuxOrderKey/mint(after:before:known:seed:)``, the
///    one minting entry point, must never trap and never return an
///    out-of-order key, whatever it is given.
/// 2. (#2) Keys grow without bound: repeated bumps to the top must step the
///    integer head down (1000 top inserts stay under 8 characters), repeated
///    drops into one gap grow about 0.17 characters each, and the batch
///    re-key (``SupermuxOrderKey/keys(between:and:count:)``) spreads short keys
///    in order.
/// 3. (#3) A malformed, oversized or hostile key from the wire (an old or buggy
///    peer) is accepted: ``SupermuxOrderKey/isValid(_:)`` must reject it, and a
///    bound that is not valid counts as no key.
/// 4. (#6) A minted key falls outside (lower, upper), so a drop lands
///    elsewhere: the port must match rocicorp's own vectors, and `mint` must
///    use `between(lower, upper)` whenever lower < upper.
/// 5. (§2.2 branches 2-5) With equal or out-of-order neighbours the key does
///    not land right after the predecessor; a window with no keyed neighbour
///    zippers into the keys this device already knows instead of starting a
///    block after them; with nothing known the first key is not stable across
///    launches (Swift's per-process `hashValue`), so a relaunch moves rows.
@Suite struct SupermuxOrderKeyTests {
    private let keys = SupermuxOrderKey()

    // MARK: rocicorp vectors (4)

    struct BetweenCase: Sendable, CustomTestStringConvertible {
        let lower: String?
        let upper: String?
        let expected: String?
        var testDescription: String { "\(lower ?? "nil") .. \(upper ?? "nil") -> \(expected ?? "nil")" }
    }

    /// rocicorp/fractional-indexing `src/test.js` (default base-62 digits).
    static let rocicorpVectors: [BetweenCase] = [
        BetweenCase(lower: nil, upper: nil, expected: "a0"),
        BetweenCase(lower: nil, upper: "a0", expected: "Zz"),
        BetweenCase(lower: nil, upper: "Zz", expected: "Zy"),
        BetweenCase(lower: "a0", upper: nil, expected: "a1"),
        BetweenCase(lower: "a1", upper: nil, expected: "a2"),
        BetweenCase(lower: "a0", upper: "a1", expected: "a0V"),
        BetweenCase(lower: "a1", upper: "a2", expected: "a1V"),
        BetweenCase(lower: "a0V", upper: "a1", expected: "a0l"),
        BetweenCase(lower: "Zz", upper: "a0", expected: "ZzV"),
        BetweenCase(lower: "Zz", upper: "a1", expected: "a0"),
        BetweenCase(lower: nil, upper: "Y00", expected: "Xzzz"),
        BetweenCase(lower: "bzz", upper: nil, expected: "c000"),
        BetweenCase(lower: "a0", upper: "a0V", expected: "a0G"),
        BetweenCase(lower: "a0", upper: "a0G", expected: "a08"),
        BetweenCase(lower: "b125", upper: "b129", expected: "b127"),
        BetweenCase(lower: "a0", upper: "a1V", expected: "a1"),
        BetweenCase(lower: "Zz", upper: "a01", expected: "a0"),
        BetweenCase(lower: nil, upper: "a0V", expected: "a0"),
        BetweenCase(lower: nil, upper: "b999", expected: "b99"),
        BetweenCase(lower: nil, upper: "A000000000000000000000000001", expected: "A000000000000000000000000000V"),
        BetweenCase(lower: "zzzzzzzzzzzzzzzzzzzzzzzzzzy", upper: nil, expected: "zzzzzzzzzzzzzzzzzzzzzzzzzzz"),
        BetweenCase(lower: "zzzzzzzzzzzzzzzzzzzzzzzzzzz", upper: nil, expected: "zzzzzzzzzzzzzzzzzzzzzzzzzzzV"),
    ]

    @Test(arguments: rocicorpVectors)
    func betweenMatchesTheReference(_ vector: BetweenCase) {
        #expect(keys.between(vector.lower, vector.upper) == vector.expected)
    }

    /// rocicorp throws on these; the port returns `nil` instead (1, 3).
    static let refusedVectors: [BetweenCase] = [
        BetweenCase(lower: nil, upper: "A00000000000000000000000000", expected: nil),
        BetweenCase(lower: "a00", upper: nil, expected: nil),
        BetweenCase(lower: "a00", upper: "a1", expected: nil),
        BetweenCase(lower: "0", upper: "1", expected: nil),
        BetweenCase(lower: "a1", upper: "a0", expected: nil),
        BetweenCase(lower: "a1", upper: "a1", expected: nil),
        BetweenCase(lower: "a0", upper: "!!", expected: nil),
    ]

    @Test(arguments: refusedVectors)
    func betweenRefusesInsteadOfTrapping(_ vector: BetweenCase) {
        #expect(keys.between(vector.lower, vector.upper) == nil)
    }

    struct BatchCase: Sendable, CustomTestStringConvertible {
        let lower: String?
        let upper: String?
        let expected: [String]
        var testDescription: String { "\(lower ?? "nil") .. \(upper ?? "nil") x\(expected.count)" }
    }

    /// `generateNKeysBetween` with the default base-62 digits, from the reference implementation.
    static let batchVectors: [BatchCase] = [
        BatchCase(lower: nil, upper: nil, expected: ["a0", "a1", "a2", "a3", "a4"]),
        BatchCase(lower: "a4", upper: nil, expected: ["a5", "a6", "a7", "a8", "a9", "aA", "aB", "aC", "aD", "aE"]),
        BatchCase(lower: nil, upper: "a0", expected: ["Zv", "Zw", "Zx", "Zy", "Zz"]),
        BatchCase(lower: "a0", upper: "a1", expected: ["a08", "a0G", "a0O", "a0V", "a0d", "a0l", "a0t"]),
        BatchCase(
            lower: "a0",
            upper: "a2",
            expected: [
                "a04", "a08", "a0G", "a0K", "a0O", "a0V", "a0Z", "a0d", "a0l", "a0t",
                "a1", "a14", "a18", "a1G", "a1O", "a1V", "a1Z", "a1d", "a1l", "a1t",
            ]
        ),
    ]

    @Test(arguments: batchVectors)
    func batchMatchesTheReference(_ vector: BatchCase) {
        #expect(keys.keys(between: vector.lower, and: vector.upper, count: vector.expected.count) == vector.expected)
    }

    @Test func batchWithNothingToMakeIsEmpty() {
        #expect(keys.keys(between: "a0", and: "a1", count: 0).isEmpty)
        #expect(keys.keys(between: "a0", and: "a1", count: -3).isEmpty)
        #expect(keys.keys(between: "a1", and: "a0", count: 2).isEmpty)
        #expect(keys.keys(between: "a00", and: nil, count: 2).isEmpty)
    }

    /// rocicorp's `testOrdering`: 1000 inserts at pseudo-random positions.
    @Test func randomInsertsAlwaysLandBetweenTheirNeighbours() {
        var generator = SeededGenerator(seed: 1)
        var list: [String] = []
        for _ in 0..<1000 {
            let position = Int(generator.next() % UInt64(list.count + 1))
            let lower = position > 0 ? list[position - 1] : nil
            let upper = position < list.count ? list[position] : nil
            guard let key = keys.between(lower, upper) else {
                Issue.record("no key between \(lower ?? "nil") and \(upper ?? "nil")")
                return
            }
            #expect(keys.isValid(key))
            if let lower { #expect(Self.precedes(lower, key)) }
            if let upper { #expect(Self.precedes(key, upper)) }
            list.insert(key, at: position)
        }
        #expect(list == list.sorted(by: Self.precedes))
    }

    // MARK: Growth (2)

    @Test func topInsertsStayShort() {
        var top = "a0"
        var longest = top.count
        for _ in 0..<1000 {
            let key = keys.mint(after: nil, before: top, known: [top], seed: "s")
            #expect(Self.precedes(key, top))
            top = key
            longest = max(longest, key.count)
        }
        #expect(longest < 8)
        #expect(top == "Yks", "the reference reaches Yks after 1000 top inserts")
    }

    @Test func bottomInsertsStayShort() {
        var bottom = "a0"
        for _ in 0..<1000 {
            let key = keys.mint(after: bottom, before: nil, known: [bottom], seed: "s")
            #expect(Self.precedes(bottom, key))
            bottom = key
        }
        #expect(bottom.count < 8)
    }

    @Test func dropsIntoOneGapGrowSlowly() {
        var upper = "a1"
        for _ in 0..<100 {
            let key = keys.mint(after: "a0", before: upper, known: ["a0", upper], seed: "s")
            #expect(Self.precedes("a0", key) && Self.precedes(key, upper))
            upper = key
        }
        // About 0.17 characters per insert, matching the reference exactly.
        #expect(upper == "a000000000000000004")
    }

    /// The re-key of a run whose keys grew long (capture's rebalance) gives
    /// short keys, in order, strictly inside the run's bounds.
    @Test func aBatchReKeyIsShortAndOrdered() {
        let run = keys.keys(between: "a0", and: "a1", count: 12)
        #expect(run.count == 12)
        #expect(run == run.sorted(by: Self.precedes))
        #expect(Set(run).count == 12)
        #expect(run.allSatisfy { Self.precedes("a0", $0) && Self.precedes($0, "a1") && $0.count <= 4 })
        #expect(SupermuxOrderKey.rebalanceLength < SupermuxOrderKey.maxLength)
    }

    // MARK: Validity (3)

    @Test(arguments: [
        "a0", "Zz", "a0V", "b00", "c000", "Xzzz", "A000000000000000000000000000V",
        "zzzzzzzzzzzzzzzzzzzzzzzzzzz", "a0" + String(repeating: "1", count: 126),
    ])
    func validKeysAreAccepted(_ key: String) {
        #expect(keys.isValid(key))
    }

    @Test(arguments: [
        "", "a", "0", "!!", "a00", "a0V0", "b0", "Y0", "A00000000000000000000000000",
        "a0 ", "a0!", "a0-", "a0é", "a\u{0}1", "ａ0",
        "a0" + String(repeating: "1", count: 127),
    ])
    func malformedKeysAreRejected(_ key: String) {
        #expect(!keys.isValid(key))
    }

    @Test func theLengthBoundIsTheWireBound() {
        let atBound = "a0" + String(repeating: "1", count: SupermuxOrderKey.maxLength - 2)
        #expect(atBound.count == SupermuxOrderKey.maxLength)
        #expect(keys.isValid(atBound))
        #expect(!keys.isValid(atBound + "1"))
    }

    // MARK: mint (1, 4, 5)

    @Test func mintUsesTheGapWhenTheNeighboursAreInOrder() {
        #expect(keys.mint(after: "a0", before: "a1", known: ["a0", "a1", "a5"], seed: "s") == "a0V")
        #expect(keys.mint(after: "Zz", before: "a1", known: [], seed: "s") == "a0")
    }

    @Test func mintWithEqualNeighboursGoesRightAfterThePredecessor() {
        let key = keys.mint(after: "a1", before: "a1", known: ["a0", "a1", "a2"], seed: "s")
        #expect(Self.precedes("a1", key) && Self.precedes(key, "a2"))
    }

    @Test func mintWithOutOfOrderNeighboursGoesRightAfterThePredecessor() {
        let key = keys.mint(after: "a3", before: "a1", known: ["a5", "a1", "a3"], seed: "s")
        #expect(Self.precedes("a3", key) && Self.precedes(key, "a5"))
        let last = keys.mint(after: "a3", before: "a1", known: ["a1", "a3"], seed: "s")
        #expect(Self.precedes("a3", last))
    }

    @Test func mintWithOnlyASuccessorGoesRightBeforeIt() {
        let key = keys.mint(after: nil, before: "a5", known: ["a1", "a5", "a9"], seed: "s")
        #expect(Self.precedes("a1", key) && Self.precedes(key, "a5"))
        let top = keys.mint(after: nil, before: "a5", known: ["a5"], seed: "s")
        #expect(Self.precedes(top, "a5"))
    }

    @Test func aWindowWithNoKeyedNeighbourStartsAfterEverythingKnown() {
        let key = keys.mint(after: nil, before: nil, known: ["a7", "Zz", "a0", "a7"], seed: "s")
        #expect(Self.precedes("a7", key))
    }

    @Test func withNothingKnownTheSeededInitialKeyIsUsed() {
        let seed = "mac:7a1c1e4b-5d0e-4b0f-9c39-1e7c3f0a2b11@default"
        #expect(keys.mint(after: nil, before: nil, known: [], seed: seed) == keys.initial(seed: seed))
    }

    @Test func aBoundOrAKnownKeyThatIsNotValidCountsAsAbsent() {
        let underUpper = keys.mint(after: "!!", before: "a5", known: ["a1", "a5"], seed: "s")
        #expect(Self.precedes("a1", underUpper) && Self.precedes(underUpper, "a5"))
        let overLower = keys.mint(after: "a1", before: "a00", known: ["a1", "a5"], seed: "s")
        #expect(Self.precedes("a1", overLower) && Self.precedes(overLower, "a5"))
        #expect(keys.mint(after: nil, before: nil, known: ["zz!", ""], seed: "s") == keys.initial(seed: "s"))
    }

    /// Every combination of bounds, valid or not, equal or not: never traps,
    /// always valid, and on the right side of every bound it can honour.
    @Test func mintIsTotal() {
        let pool: [String?] = [nil, "a0", "a0V", "a1", "Zz", "a00", "!!", "a1", "b00", "A000000000000000000000000000V"]
        let knownSets: [[String]] = [[], ["a0", "a1"], ["a1", "a1", "Zz", "b00"], ["!!", "a0V"]]
        for lower in pool {
            for upper in pool {
                for known in knownSets {
                    let key = keys.mint(after: lower, before: upper, known: known, seed: "s")
                    #expect(keys.isValid(key), "\(lower ?? "nil") .. \(upper ?? "nil")")
                    let validLower = lower.flatMap { keys.isValid($0) ? $0 : nil }
                    let validUpper = upper.flatMap { keys.isValid($0) ? $0 : nil }
                    if let validLower { #expect(Self.precedes(validLower, key)) }
                    if let validUpper, validLower.map({ Self.precedes($0, validUpper) }) ?? true {
                        #expect(Self.precedes(key, validUpper))
                    }
                }
            }
        }
    }

    // MARK: initial (5)

    @Test func theInitialKeyIsAValidThreeCharacterBlock() {
        for seed in ["", "mac:a@default", "mac:b@nightly", "phone:x"] {
            let key = keys.initial(seed: seed)
            #expect(keys.isValid(key))
            #expect(key.count == 3 && key.hasPrefix("b"))
            #expect(keys.initial(seed: seed) == key)
        }
    }

    /// Pinned values: the seed hash must not change between launches or devices.
    @Test func theInitialKeyIsStableAcrossLaunches() {
        #expect(keys.initial(seed: "mac:7a1c1e4b-5d0e-4b0f-9c39-1e7c3f0a2b11@default") == "bRt")
        #expect(keys.initial(seed: "mac:0f6e9c2a-3b4d-4e5f-8a7b-9c0d1e2f3a4b@default") == "bvE")
    }

    // MARK: Helpers

    /// Byte order, the order every device sorts keys in.
    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

/// rocicorp's linear congruential generator, so the fuzz is repeatable.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = (state &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
        return state
    }
}

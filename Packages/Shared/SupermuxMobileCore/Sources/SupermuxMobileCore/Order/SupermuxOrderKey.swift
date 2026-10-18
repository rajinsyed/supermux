// The key algebra is a Swift port of rocicorp/fractional-indexing
// (https://github.com/rocicorp/fractional-indexing, CC0 1.0, no rights
// reserved), itself based on David Greenspan's "Implementing Fractional
// Indexing" (https://observablehq.com/@dgreensp/implementing-fractional-indexing).
// `between` is `generateKeyBetween` and `keys(between:and:count:)` is
// `generateNKeysBetween`, both with the default base-62 digits and the classic
// A-Z/a-z integer heads. Where the original throws, the port returns nil.

/// The fractional order key that places one workspace among all of the
/// user's workspaces, on every Mac and on the phone.
///
/// A key is an integer part (a head letter that encodes its length, then
/// base-62 digits) followed by an optional fraction with no trailing `0`.
/// Keys sort in plain byte order, and a key fits between any two others, so
/// moving one row re-keys only that row. Only the Mac that owns a workspace
/// writes its key; every other device reads it.
///
/// ```swift
/// let keys = SupermuxOrderKey()
/// keys.between("a0", "a1")       // "a0V"
/// keys.between(nil, "a0")        // "Zz": a bump to the top
/// keys.between("a1", "a1")       // nil: no key fits, never a trap
/// keys.mint(after: "a1", before: "a1", known: ["a1", "a2"], seed: origin)  // "a1V"
/// ```
public struct SupermuxOrderKey: Sendable {
    /// The longest key any device accepts. A longer key from the wire counts as no key.
    public static let maxLength = 128
    /// The length past which the owner re-keys a run of its own rows with
    /// short keys, well before keys reach ``maxLength``.
    public static let rebalanceLength = 64

    /// Creates the key algebra.
    public init() {}

    /// Whether `key` is a well-formed order key no longer than ``maxLength``.
    ///
    /// A key from the wire is used only when this holds; otherwise the row
    /// counts as unkeyed.
    /// - Parameter key: The candidate key.
    /// - Returns: `true` for a valid key.
    public func isValid(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return bytes.count <= Self.maxLength && Self.isWellFormed(bytes)
    }

    /// A key strictly between `lower` and `upper`.
    ///
    /// - Parameters:
    ///   - lower: The key it must sort after, or `nil` for the start.
    ///   - upper: The key it must sort before, or `nil` for the end.
    /// - Returns: The key, or `nil` when either bound is not valid or
    ///   `lower` is not below `upper`. Never traps. The key is at most one
    ///   character longer than the longer bound.
    public func between(_ lower: String?, _ upper: String?) -> String? {
        guard let bounds = bounds(lower, upper) else { return nil }
        let key = Self.keyBetween(bounds.lower, bounds.upper)
        guard Self.isAscending([bounds.lower, key, bounds.upper]) else { return nil }
        return String(decoding: key, as: UTF8.self)
    }

    /// `count` ascending keys strictly between `lower` and `upper`, spread
    /// evenly and kept short. Re-keys a run of rows at once.
    ///
    /// - Parameters:
    ///   - lower: The key the run must sort after, or `nil` for the start.
    ///   - upper: The key the run must sort before, or `nil` for the end.
    ///   - count: How many keys to make.
    /// - Returns: The keys in order, or an empty array when `count` is not
    ///   positive or no key fits (a bound is not valid, or `lower` ≥ `upper`).
    public func keys(between lower: String?, and upper: String?, count: Int) -> [String] {
        guard count > 0, let bounds = bounds(lower, upper) else { return [] }
        let keys = Self.keysBetween(bounds.lower, bounds.upper, count: count)
        guard Self.isAscending([bounds.lower] + keys.map(Optional.some) + [bounds.upper]) else { return [] }
        return keys.map { String(decoding: $0, as: UTF8.self) }
    }

    /// The first key of a device that knows no key yet: `b` and two base-62
    /// digits of a stable hash of `seed`.
    ///
    /// Two Macs that upgrade at the same moment seed with their own origins,
    /// so their rows form separate blocks instead of interleaving.
    /// - Parameter seed: The minting device's origin, such as `mac:<device>@<tag>`.
    /// - Returns: A valid three-character key, the same on every launch and device.
    public func initial(seed: String) -> String {
        // FNV-1a: Swift's `hashValue` changes on every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let base = UInt64(Self.digits.count)
        let high = Self.digits[Int((hash / base) % base)]
        let low = Self.digits[Int(hash % base)]
        return String(decoding: [UInt8(ascii: "b"), high, low], as: UTF8.self)
    }

    /// The key for a row that lands between two neighbours. The one minting
    /// entry point: it never traps and never returns an out-of-order key.
    ///
    /// In order of preference:
    /// 1. Between the neighbours, when `lower` < `upper`.
    /// 2. Right after the predecessor: between `lower` and the next known key
    ///    (equal-key or out-of-order neighbours).
    /// 3. Right before the successor: between the previous known key and `upper`.
    /// 4. After every known key, so a window with no keyed neighbour starts a
    ///    new block instead of zippering into the others.
    /// 5. ``initial(seed:)`` when nothing is known.
    ///
    /// A bound or known key that is not valid counts as absent.
    /// - Parameters:
    ///   - lower: The key of the row before it, if keyed.
    ///   - upper: The key of the row after it, if keyed.
    ///   - known: Every key the device knows, in any order, without the key of
    ///     the row being re-keyed.
    ///   - seed: The minting device's origin, for ``initial(seed:)``.
    /// - Returns: The key. It is valid unless a bound is already about
    ///   ``maxLength`` long, which re-keying at ``rebalanceLength`` prevents.
    public func mint(after lower: String?, before upper: String?, known: [String], seed: String) -> String {
        let lower = lower.flatMap { isValid($0) ? $0 : nil }
        let upper = upper.flatMap { isValid($0) ? $0 : nil }
        let known = Set(known.filter(isValid)).sorted(by: Self.precedes)
        if let lower, let upper, let key = between(lower, upper) {
            return key
        }
        if let lower, let key = between(lower, known.first(where: { Self.precedes(lower, $0) })) {
            return key
        }
        if let upper, let key = between(known.last(where: { Self.precedes($0, upper) }), upper) {
            return key
        }
        if let last = known.last, let key = between(last, nil) {
            return key
        }
        return initial(seed: seed)
    }

    /// The bounds as bytes, or `nil` when either is not valid or they are out of order.
    private func bounds(_ lower: String?, _ upper: String?) -> (lower: [UInt8]?, upper: [UInt8]?)? {
        if let lower, !isValid(lower) { return nil }
        if let upper, !isValid(upper) { return nil }
        let bytes = (lower: lower.map { Array($0.utf8) }, upper: upper.map { Array($0.utf8) })
        guard Self.isAscending([bytes.lower, bytes.upper]) else { return nil }
        return bytes
    }

    /// Byte order: the order every device sorts keys in.
    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Whether the present keys strictly ascend (a `nil` bound is open).
    private static func isAscending(_ keys: [[UInt8]?]) -> Bool {
        let present = keys.compactMap { $0 }
        return zip(present, present.dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) }
    }
}

// MARK: - The rocicorp algorithm on bytes

extension SupermuxOrderKey {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let zero = UInt8(ascii: "0")
    private static let largestDigit = UInt8(ascii: "z")
    /// `A` and 26 zeros: the smallest integer, which no key may equal (nothing fits below it).
    private static let smallestInteger = [UInt8(ascii: "A")] + Array(repeating: zero, count: 26)

    private static func digitValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return Int(byte - UInt8(ascii: "A")) + 10
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(byte - UInt8(ascii: "a")) + 36
        default: return nil
        }
    }

    /// The integer part's length, head included: `a` is 2, `b` 3 … `z` 27;
    /// `Z` is 2, `Y` 3 … `A` 27.
    private static func integerLength(head: UInt8) -> Int? {
        switch head {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return Int(UInt8(ascii: "Z") - head) + 2
        default: return nil
        }
    }

    private static func isWellFormed(_ key: [UInt8]) -> Bool {
        guard let head = key.first,
              let length = integerLength(head: head),
              length <= key.count,
              key.dropFirst().allSatisfy({ digitValue($0) != nil }),
              key != smallestInteger else { return false }
        return key.count == length || key.last != zero
    }

    private static func integerPart(_ key: [UInt8]) -> [UInt8] {
        Array(key.prefix(key.first.flatMap { integerLength(head: $0) } ?? key.count))
    }

    /// `generateKeyBetween` for valid keys with `lower` < `upper`.
    private static func keyBetween(_ lower: [UInt8]?, _ upper: [UInt8]?) -> [UInt8] {
        switch (lower, upper) {
        case (nil, nil):
            return [UInt8(ascii: "a"), zero]
        case let (nil, upper?):
            let integer = integerPart(upper)
            let fraction = Array(upper.dropFirst(integer.count))
            if integer == smallestInteger {
                return integer + midpoint([], fraction)
            }
            if integer.count < upper.count {
                return integer
            }
            return decrement(integer) ?? integer + midpoint([], fraction)
        case let (lower?, nil):
            let integer = integerPart(lower)
            let fraction = Array(lower.dropFirst(integer.count))
            return increment(integer) ?? integer + midpoint(fraction, nil)
        case let (lower?, upper?):
            let lowerInteger = integerPart(lower)
            let lowerFraction = Array(lower.dropFirst(lowerInteger.count))
            let upperInteger = integerPart(upper)
            if lowerInteger == upperInteger {
                return lowerInteger + midpoint(lowerFraction, Array(upper.dropFirst(upperInteger.count)))
            }
            if let next = increment(lowerInteger), next.lexicographicallyPrecedes(upper) {
                return next
            }
            return lowerInteger + midpoint(lowerFraction, nil)
        }
    }

    /// `generateNKeysBetween` for valid keys with `lower` < `upper`.
    private static func keysBetween(_ lower: [UInt8]?, _ upper: [UInt8]?, count: Int) -> [[UInt8]] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [keyBetween(lower, upper)] }
        guard let upper else {
            var key = keyBetween(lower, nil)
            var keys = [key]
            for _ in 1..<count {
                key = keyBetween(key, nil)
                keys.append(key)
            }
            return keys
        }
        guard let lower else {
            var key = keyBetween(nil, upper)
            var keys = [key]
            for _ in 1..<count {
                key = keyBetween(nil, key)
                keys.append(key)
            }
            return keys.reversed()
        }
        let half = count / 2
        let middle = keyBetween(lower, upper)
        return keysBetween(lower, middle, count: half) + [middle] + keysBetween(middle, upper, count: count - half - 1)
    }

    /// A fraction strictly between `lower` and `upper` (`nil` is the end).
    /// Neither may end in `0`, and `lower` < `upper`.
    private static func midpoint(_ lower: [UInt8], _ upper: [UInt8]?) -> [UInt8] {
        if let upper {
            // Drop the longest common prefix, padding `lower` with zeros.
            var shared = 0
            while shared < upper.count, (shared < lower.count ? lower[shared] : zero) == upper[shared] {
                shared += 1
            }
            if shared > 0 {
                return Array(upper.prefix(shared))
                    + midpoint(Array(lower.dropFirst(shared)), Array(upper.dropFirst(shared)))
            }
        }
        // The first digits (or the lack of one) differ.
        let lowerDigit = lower.first.flatMap(digitValue) ?? 0
        let upperDigit = upper.map { $0.first.flatMap(digitValue) ?? 0 } ?? digits.count
        if upperDigit - lowerDigit > 1 {
            // Rounds half up, as JavaScript's `Math.round` does.
            return [digits[(lowerDigit + upperDigit + 1) / 2]]
        }
        if let upper, upper.count > 1 {
            return [upper[0]]
        }
        return [digits[lowerDigit]] + midpoint(Array(lower.dropFirst()), nil)
    }

    /// The next integer, or `nil` past the largest one.
    private static func increment(_ integer: [UInt8]) -> [UInt8]? {
        guard let head = integer.first else { return nil }
        var body = Array(integer.dropFirst())
        for index in body.indices.reversed() {
            let value = (digitValue(body[index]) ?? 0) + 1
            if value < digits.count {
                body[index] = digits[value]
                return [head] + body
            }
            body[index] = zero
        }
        // Carried out of every digit: the next head.
        switch head {
        case UInt8(ascii: "Z"): return [UInt8(ascii: "a"), zero]
        case UInt8(ascii: "z"): return nil
        default:
            let next = head + 1
            return [next] + (next > UInt8(ascii: "a") ? body + [zero] : Array(body.dropLast()))
        }
    }

    /// The previous integer, or `nil` below the smallest one.
    private static func decrement(_ integer: [UInt8]) -> [UInt8]? {
        guard let head = integer.first else { return nil }
        var body = Array(integer.dropFirst())
        for index in body.indices.reversed() {
            let value = (digitValue(body[index]) ?? 0) - 1
            if value >= 0 {
                body[index] = digits[value]
                return [head] + body
            }
            body[index] = largestDigit
        }
        // Borrowed out of every digit: the previous head.
        switch head {
        case UInt8(ascii: "a"): return [UInt8(ascii: "Z"), largestDigit]
        case UInt8(ascii: "A"): return nil
        default:
            let previous = head - 1
            return [previous] + (previous < UInt8(ascii: "Z") ? body + [largestDigit] : Array(body.dropLast()))
        }
    }
}

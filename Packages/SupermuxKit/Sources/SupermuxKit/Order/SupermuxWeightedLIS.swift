/// A maximum-weight strictly increasing subsequence: the largest set of rows
/// that kept their relative order since the last capture pass, where some
/// rows count more than others.
///
/// The capture planner weighs a programmatic move 0, a hinted (user-moved)
/// row 1 and any other row 2, so the rows it keeps are the ones that did not
/// move, and the rows left out are the movers. O(n²), run only when a window's
/// rows changed.
///
/// ```swift
/// SupermuxWeightedLIS().indices(of: [1, 0], weights: [1, 2])  // [1]: the hinted row 0 moved
/// ```
struct SupermuxWeightedLIS: Sendable {
    /// The positions, ascending, of a strictly increasing subsequence of
    /// `values` whose `weights` sum highest.
    ///
    /// On a tie the subsequence that ends first wins, built from the
    /// earliest predecessors, so the result is deterministic.
    /// - Parameters:
    ///   - values: The sequence (each row's previous position).
    ///   - weights: Each value's weight, at least 0; extra entries of the
    ///     longer array are ignored.
    /// - Returns: Positions into `values`, ascending.
    func indices(of values: [Int], weights: [Int]) -> [Int] {
        let count = min(values.count, weights.count)
        guard count > 0 else { return [] }
        var best = Array(weights.prefix(count))
        var previous = [Int?](repeating: nil, count: count)
        for index in 0..<count {
            for candidate in 0..<index where values[candidate] < values[index]
                && best[candidate] + weights[index] > best[index] {
                best[index] = best[candidate] + weights[index]
                previous[index] = candidate
            }
        }
        var end: Int? = 0
        for index in 1..<count where best[index] > best[end ?? 0] {
            end = index
        }
        var chain: [Int] = []
        while let index = end {
            chain.append(index)
            end = previous[index]
        }
        return chain.reversed()
    }
}

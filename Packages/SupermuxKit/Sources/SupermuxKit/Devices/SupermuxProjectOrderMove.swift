public import Foundation
public import SupermuxMobileCore

/// Plans one project move in the shared order (DESIGN §3.4.2): which projects
/// take a new stamp, keyed by unified id. Pure; the app writes the stamps.
///
/// It stamps only the moved project when every project is stamped and a key
/// fits between its new neighbours; otherwise (the first move anywhere, a
/// project added since, neighbours with equal keys) it stamps every project
/// in the new order at once, with one `updatedAt`.
///
/// ```swift
/// let move = SupermuxProjectOrderMove(origin: "mac:7a1c@default", now: Date())
/// let stamps = move.stamps(moving: dragged, over: target, in: list.sharedOrder)
/// ```
public struct SupermuxProjectOrderMove: Sendable {
    /// The mover in stamps: `mac:<device>@<tag>`.
    public let origin: String
    /// The mover's clock.
    public let now: Date
    private let orderKey = SupermuxOrderKey()

    /// Creates a planner for one move.
    /// - Parameters:
    ///   - origin: The mover in stamps.
    ///   - now: The mover's clock.
    public init(origin: String, now: Date) {
        self.origin = origin
        self.now = now
    }

    /// The new stamps for moving `dragged` next to `target`: after it when
    /// moving down, before it when moving up (the sidebar's rule).
    /// - Parameters:
    ///   - dragged: The unified id of the project being moved.
    ///   - target: The unified id of the project it is dropped over.
    ///   - order: The projects in the shared order
    ///     (``SupermuxUnifiedProjectList/sharedOrder``).
    /// - Returns: The stamps by unified id; empty when the move does nothing.
    public func stamps(
        moving dragged: UUID,
        over target: UUID,
        in order: [SupermuxUnifiedProject]
    ) -> [UUID: SupermuxOrderStamp] {
        var order = order
        guard SupermuxProjectsModel.applyMove(dragged, over: target, in: &order),
              let index = order.firstIndex(where: { $0.id == dragged }) else { return [:] }
        return stamps(movingProjectAt: index, in: order)
    }

    private func stamps(movingProjectAt index: Int, in order: [SupermuxUnifiedProject]) -> [UUID: SupermuxOrderStamp] {
        let observed = order.compactMap(\.order)
        if observed.count == order.count, let key = keyBetweenNeighbours(of: index, in: order) {
            let stamp = SupermuxOrderStamp.next(key: key, observed: observed, origin: origin, now: now)
            return [order[index].id: stamp]
        }
        let keys = orderKey.keys(between: nil, and: nil, count: order.count)
        return Dictionary(
            zip(order, keys).map { project, key in
                (project.id, SupermuxOrderStamp.next(key: key, observed: observed, origin: origin, now: now))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// A valid key strictly between the keys of the projects around `index`,
    /// or `nil` when none fits (equal neighbour keys, or a gap too deep).
    private func keyBetweenNeighbours(of index: Int, in order: [SupermuxUnifiedProject]) -> String? {
        let lower = index > order.startIndex ? order[index - 1].order?.key : nil
        let upper = index + 1 < order.endIndex ? order[index + 1].order?.key : nil
        guard let key = orderKey.between(lower, upper), orderKey.isValid(key) else { return nil }
        return key
    }
}

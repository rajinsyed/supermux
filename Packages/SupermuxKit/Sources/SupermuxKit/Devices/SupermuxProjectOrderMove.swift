public import Foundation
public import SupermuxMobileCore

/// Plans one project move in the shared order (DESIGN §3.4.2): which projects
/// take a new stamp, keyed by unified id. Pure; the app writes the stamps.
///
/// It plans over the keyed projects only (``SupermuxUnifiedProject/isOrderKeyed``):
/// a project no copy of which can hold a stamp keeps sorting after them and is
/// never moved; a row dropped over it lands in the nearest keyed slot. Among
/// the keyed ones it stamps only the moved project when every one is stamped
/// and a key fits between its new neighbours; otherwise (the first move
/// anywhere, a project added since, neighbours with equal keys) it stamps
/// every keyed project in the new order at once, with one `updatedAt`. That
/// restamp keys around the stamped projects no copy of which takes a stamp now
/// (a Mac asleep): they keep their keys, and only when two of them leave no
/// room between them does it re-key them too.
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
    /// - Returns: The stamps by unified id; empty when the move does nothing
    ///   or the dragged project is not keyed.
    public func stamps(
        moving dragged: UUID,
        over target: UUID,
        in order: [SupermuxUnifiedProject]
    ) -> [UUID: SupermuxOrderStamp] {
        var order = order
        guard order.first(where: { $0.id == dragged })?.isOrderKeyed == true,
              SupermuxProjectsModel.applyMove(dragged, over: target, in: &order) else { return [:] }
        let keyed = order.filter(\.isOrderKeyed)
        guard let index = keyed.firstIndex(where: { $0.id == dragged }) else { return [:] }
        return stamps(movingProjectAt: index, in: keyed)
    }

    private func stamps(movingProjectAt index: Int, in order: [SupermuxUnifiedProject]) -> [UUID: SupermuxOrderStamp] {
        let observed = order.compactMap(\.order)
        if observed.count == order.count, let key = keyBetweenNeighbours(of: index, in: order) {
            let stamp = SupermuxOrderStamp.next(key: key, observed: observed, origin: origin, now: now)
            return [order[index].id: stamp]
        }
        let keys = keysAroundAnchors(in: order) ?? Dictionary(
            zip(order.map(\.id), orderKey.keys(between: nil, and: nil, count: order.count)),
            uniquingKeysWith: { first, _ in first }
        )
        return keys.mapValues { key in
            SupermuxOrderStamp.next(key: key, observed: observed, origin: origin, now: now)
        }
    }

    /// New keys for every project in `order` except the anchors (stamped, but
    /// no copy takes a stamp now), each run between two anchors keyed strictly
    /// between their keys; `nil` when a run has no room.
    private func keysAroundAnchors(in order: [SupermuxUnifiedProject]) -> [UUID: String]? {
        var keys: [UUID: String] = [:]
        var run: [UUID] = []
        var lower: String?
        for project in order.map(Optional.some) + [nil] {
            if let project, !Self.isAnchor(project) {
                run.append(project.id)
                continue
            }
            let upper = project?.order?.key
            let runKeys = orderKey.keys(between: lower, and: upper, count: run.count)
            guard runKeys.count == run.count else { return nil }
            keys.merge(zip(run, runKeys), uniquingKeysWith: { first, _ in first })
            run = []
            lower = upper
        }
        return keys
    }

    /// A stamped project no copy of which takes a stamp now: its key stays.
    private static func isAnchor(_ project: SupermuxUnifiedProject) -> Bool {
        project.order != nil && !project.takesOrderStamp
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

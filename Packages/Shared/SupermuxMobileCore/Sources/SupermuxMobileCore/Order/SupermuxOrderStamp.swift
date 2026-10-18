import Foundation

/// The order stamp on one copy of a project: its order key, when that order
/// was set and by whom. The newest stamp wins on every device.
///
/// One `Codable` shape for the projects file, the `projects.list` DTO and the
/// `projects.set_order` RPC: `{"key", "updated_at", "origin"}`.
///
/// ```swift
/// let stamp = SupermuxOrderStamp.next(key: key, observed: shownStamps, origin: origin, now: Date())
/// if stamp.wins(over: copy.order) { copy.order = stamp }
/// ```
public struct SupermuxOrderStamp: Codable, Hashable, Sendable {
    /// The project's ``SupermuxOrderKey``.
    public let key: String
    /// When the order was set, in Unix seconds.
    public let updatedAt: Double
    /// Who set it: `mac:<device>@<tag>` or `phone:<launch id>`. Only breaks
    /// ties between stamps set at the same instant.
    public let origin: String

    enum CodingKeys: String, CodingKey {
        case key
        case updatedAt = "updated_at"
        case origin
    }

    /// Creates a stamp.
    /// - Parameters:
    ///   - key: The project's order key.
    ///   - updatedAt: When the order was set, in Unix seconds.
    ///   - origin: Who set it.
    public init(key: String, updatedAt: Double, origin: String) {
        self.key = key
        self.updatedAt = updatedAt
        self.origin = origin
    }

    /// Whether the key is a valid order key and the time is finite. A stamp
    /// that is not valid counts as no stamp.
    public var isValid: Bool {
        SupermuxOrderKey().isValid(key) && updatedAt.isFinite
    }

    /// Whether this stamp replaces `other`: it is valid, and `other` is
    /// missing, not valid, or older by `(updatedAt, origin, key)`.
    ///
    /// The comparison is a total order, so every device picks the same copy
    /// even when one restamp gave two copies the same time and origin. A
    /// stamp never wins over itself, so applying it again changes nothing.
    /// - Parameter other: The copy's current stamp.
    /// - Returns: `true` when this stamp should replace it.
    public func wins(over other: Self?) -> Bool {
        guard isValid else { return false }
        guard let other, other.isValid else { return true }
        if updatedAt != other.updatedAt {
            return updatedAt > other.updatedAt
        }
        if origin != other.origin {
            return other.origin.utf8.lexicographicallyPrecedes(origin.utf8)
        }
        return other.key.utf8.lexicographicallyPrecedes(key.utf8)
    }

    /// The stamp for a move, which beats every stamp the mover saw even when
    /// another device's clock runs ahead: `updatedAt` is the later of `now`
    /// and a millisecond after the newest observed stamp.
    /// - Parameters:
    ///   - key: The moved project's new order key.
    ///   - observed: The stamps the mover can see.
    ///   - origin: The mover.
    ///   - now: The mover's clock.
    /// - Returns: The new stamp.
    public static func next(key: String, observed: [Self], origin: String, now: Date) -> Self {
        let clock = now.timeIntervalSince1970
        let newest = observed.filter(\.isValid).map(\.updatedAt).max()
        let updatedAt = newest.map { max(clock, $0 + 0.001) } ?? clock
        return Self(key: key, updatedAt: updatedAt, origin: origin)
    }
}

import Foundation

public struct SupermuxOrderStamp: Codable, Hashable, Sendable {
    public let key: String
    public let updatedAt: Double
    public let origin: String
    enum CodingKeys: String, CodingKey {
        case key
        case updatedAt = "updated_at"
        case origin
    }
    public init(key: String, updatedAt: Double, origin: String) {
        self.key = key
        self.updatedAt = updatedAt
        self.origin = origin
    }
    public var isValid: Bool { false }
    public func wins(over other: Self?) -> Bool { false }
    public static func next(key: String, observed: [Self], origin: String, now: Date) -> Self {
        Self(key: key, updatedAt: 0, origin: origin)
    }
}

import Foundation

public struct SupermuxOrderKey: Sendable {
    public static let maxLength = 128
    public static let rebalanceLength = 64
    public init() {}
    public func isValid(_ key: String) -> Bool { false }
    public func between(_ lower: String?, _ upper: String?) -> String? { nil }
    public func keys(between lower: String?, and upper: String?, count: Int) -> [String] { [] }
    public func initial(seed: String) -> String { "" }
    public func mint(after lower: String?, before upper: String?, known: [String], seed: String) -> String { "" }
}

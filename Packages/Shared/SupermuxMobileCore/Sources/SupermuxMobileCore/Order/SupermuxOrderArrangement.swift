public struct SupermuxOrderArrangement: Sendable {
    public init() {}
    public func arrange<ID>(_ items: [SupermuxOrderItem<ID>]) -> [ID] { [] }
}

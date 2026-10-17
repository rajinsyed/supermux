public struct SupermuxProjectOrder: Sendable {
    public init() {}
    public func sorted<T>(_ items: [T], stamp: (T) -> SupermuxOrderStamp?) -> [T] { [] }
}

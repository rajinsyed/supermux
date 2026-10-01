public import Foundation

/// Blocking file-system lookups on a device RPC path (a stat, an icon read)
/// that must never hold up their caller.
///
/// Today each lookup runs inline on the caller.
public final class SupermuxBoundedLookups<Value: Sendable>: @unchecked Sendable {
    public init() {}

    /// Runs each lookup and answers with the values that finished within
    /// `timeout`, keyed like `lookups`.
    public func values(_ lookups: [String: @Sendable () -> Value], timeout: TimeInterval) async -> [String: Value] {
        lookups.mapValues { $0() }
    }

    /// One lookup's value, or `nil` when it did not finish within `timeout`.
    public func value(_ key: String, timeout: TimeInterval, lookup: @escaping @Sendable () -> Value) async -> Value? {
        await values([key: lookup], timeout: timeout)[key]
    }
}

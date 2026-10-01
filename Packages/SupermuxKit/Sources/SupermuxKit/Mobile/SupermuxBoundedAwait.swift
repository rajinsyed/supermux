public import Foundation

/// Waits for async work at most a bound: the work's value when it finishes in
/// time, otherwise `nil` at the bound. The work keeps running in its own task
/// to its end; only the caller stops waiting for it.
///
/// The host uses it where a device RPC waits on shared async work that file
/// or git access can hold up (the projects model's first load, the git origin
/// lookups): in a folder whose macOS privacy prompt nobody answers, such
/// access blocks in the kernel, where not even a kill ends it, and the
/// caller's reply deadline must still be met. Like ``SupermuxBoundedWork``,
/// the bound is timed on a queue of its own, never on Swift's cooperative
/// pool, which stuck work can fill.
///
/// ```swift
/// let loaded = await SupermuxBoundedAwait(timeout: 2).value { await model.loadIfNeeded() } != nil
/// ```
public struct SupermuxBoundedAwait: Sendable {
    /// Seconds before the caller stops waiting.
    public let timeout: TimeInterval

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Fires the bounds. A queue of its own overcommits: it is never left
    /// waiting for a thread that stuck work holds.
    private static let deadlines = DispatchQueue(label: "supermux.bounded-await.deadlines", qos: .userInitiated)

    /// The work's value, or `nil` once ``timeout`` passes first.
    public func value<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value? {
        let timeout = self.timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let answer = SupermuxFirstAnswer<Value?>(continuation)
            Task { answer.give(await work()) }
            Self.deadlines.asyncAfter(deadline: .now() + timeout) { answer.give(nil) }
        }
    }
}

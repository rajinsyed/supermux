public import Foundation

/// Runs blocking work (file I/O, waiting for a child process) on a GCD thread
/// and answers within a bound: the work's value when it finishes in time,
/// otherwise the fallback at the bound. Work that finishes later is dropped.
///
/// The host uses it for each `files.*` call another Mac or a phone makes, so
/// the caller always gets an answer before its reply deadline (a missed
/// deadline makes the device link reconnect). The work keeps running to its
/// end; it only stops holding up the answer. It runs outside Swift's
/// cooperative pool, so stuck work never starves the app's other tasks.
///
/// The bound is timed on a private serial queue, which gets its own thread
/// even when stuck calls (a hung network volume) fill GCD's global pool, so
/// the answer still comes at the bound.
///
/// ```swift
/// let reply = await SupermuxBoundedWork(timeout: 30).run({ browser.list(...) },
///                                                         orAfterTimeout: { .timedOut })
/// ```
public struct SupermuxBoundedWork: Sendable {
    /// Seconds before the fallback answers.
    public let timeout: TimeInterval

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Fires the fallbacks. A queue of its own overcommits: it is never left
    /// waiting for a thread of the global pool the work may have filled.
    private static let deadlines = DispatchQueue(label: "supermux.bounded-work.deadlines", qos: .userInitiated)

    /// The work's value, or `fallback()` once ``timeout`` passes first.
    public func run<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value,
        orAfterTimeout fallback: @escaping @Sendable () -> Value
    ) async -> Value {
        let timeout = self.timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let answer = SupermuxFirstAnswer(continuation)
            DispatchQueue.global(qos: .userInitiated).async { answer.give(work()) }
            Self.deadlines.asyncAfter(deadline: .now() + timeout) {
                answer.give(fallback())
            }
        }
    }
}

/// Resumes a continuation with the first value it is given; later ones are
/// dropped (also ``SupermuxBoundedAwait``'s).
final class SupermuxFirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func give(_ value: Value) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}

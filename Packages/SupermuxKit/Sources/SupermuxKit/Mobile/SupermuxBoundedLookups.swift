public import Foundation

/// Blocking file-system lookups on a device RPC path (a stat, an icon read)
/// that never hold up their caller past a bound and never pile up.
///
/// A lookup can block in the kernel for as long as nobody acts: a file in
/// ~/Documents while macOS's privacy prompt for it is unanswered (nobody
/// answers it on a headless Mac), a hung network volume. So each lookup runs
/// on a thread of its own, never on Swift's cooperative pool; a key whose
/// lookup is still running is joined, never started again, so a stuck path
/// holds one thread however often it is asked for; and the caller gets, at
/// its bound, the values that finished by then. A key whose lookup ended is
/// looked up afresh next time.
///
/// ```swift
/// let tokens = await lookups.values(["icon:\(path)": { stat(path) }], timeout: 2)
/// ```
public final class SupermuxBoundedLookups<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: SupermuxLookupFlight<Value>] = [:]

    public init() {}

    /// Runs (or joins) each lookup and answers with the values that finished
    /// within `timeout`, keyed like `lookups`; the rest are absent.
    public func values(_ lookups: [String: @Sendable () -> Value], timeout: TimeInterval) async -> [String: Value] {
        guard !lookups.isEmpty else { return [:] }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Value], Never>) in
            let batch = SupermuxLookupBatch<Value>(continuation, count: lookups.count)
            for (key, lookup) in lookups {
                join(key, lookup: lookup) { value in batch.finished(key, value) }
            }
            supermuxLookupDeadlines.asyncAfter(deadline: .now() + timeout) { batch.answer() }
        }
    }

    /// One lookup's value, or `nil` when it did not finish within `timeout`.
    public func value(_ key: String, timeout: TimeInterval, lookup: @escaping @Sendable () -> Value) async -> Value? {
        await values([key: lookup], timeout: timeout)[key]
    }

    /// Calls `done` with the key's value once its lookup (the one running, or
    /// one started now on a thread of its own) ends.
    private func join(_ key: String, lookup: @escaping @Sendable () -> Value, done: @escaping @Sendable (Value) -> Void) {
        lock.lock()
        if let flight = running[key] {
            flight.waiters.append(done)
            lock.unlock()
            return
        }
        let flight = SupermuxLookupFlight<Value>()
        flight.waiters.append(done)
        running[key] = flight
        lock.unlock()
        Thread.detachNewThread {
            let value = lookup()
            self.lock.lock()
            if self.running[key] === flight { self.running[key] = nil }
            let waiters = flight.waiters
            flight.waiters = []
            self.lock.unlock()
            for waiter in waiters { waiter(value) }
        }
    }
}

/// Fires the bounds. A queue of its own overcommits: it never waits for a
/// thread of GCD's global pool, which stuck work elsewhere can fill.
private let supermuxLookupDeadlines = DispatchQueue(label: "supermux.bounded-lookups.deadlines", qos: .userInitiated)

/// One lookup in progress; its waiters are guarded by the owner's lock.
private final class SupermuxLookupFlight<Value: Sendable>: @unchecked Sendable {
    var waiters: [@Sendable (Value) -> Void] = []
}

/// The values one call collected; it answers once, when every lookup finished
/// or at the bound, whichever comes first.
private final class SupermuxLookupBatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: Value], Never>?
    private var values: [String: Value] = [:]
    private var remaining: Int

    init(_ continuation: CheckedContinuation<[String: Value], Never>, count: Int) {
        self.continuation = continuation
        remaining = count
    }

    func finished(_ key: String, _ value: Value) {
        lock.lock()
        values[key] = value
        remaining -= 1
        let done = remaining == 0
        lock.unlock()
        if done { answer() }
    }

    func answer() {
        lock.lock()
        let waiting = continuation
        continuation = nil
        let answered = values
        lock.unlock()
        waiting?.resume(returning: answered)
    }
}

public import Foundation

/// Blocking work per key (a folder's `git status`), at most one run in
/// progress and one queued per key, shared by the requests for that key.
///
/// A request for an idle key starts a run at once. A request made while the
/// key's run is going waits for the one follow-up run that starts when that
/// run ends, shared by every request made meanwhile (as the viewer's
/// `SupermuxCoalescedRefresh` does): its answer is never computed before it
/// asked, so a client that asks after a commit never gets pre-commit colors,
/// and slow work never piles up. A request that gives up at its bound leaves
/// its run going (`GitStatusProvider` cannot stop git). Each run has a thread
/// of its own (at most one per key), so runs never wait for GCD's global pool,
/// which stuck `files.*` work or anything else in the app can fill.
///
/// ```swift
/// let runs = SupermuxSharedRuns<[String: GitFileStatus]> { root in GitStatusProvider().fetchStatus(directory: root) }
/// let statuses = runs.join(root).wait(seconds: 30)   // nil while still running
/// ```
public final class SupermuxSharedRuns<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: SupermuxSharedRun<Value>] = [:]
    private var queued: [String: SupermuxSharedRun<Value>] = [:]
    private let work: @Sendable (String) -> Value

    /// - Parameter work: the blocking work for one key.
    public init(work: @escaping @Sendable (String) -> Value) {
        self.work = work
    }

    /// A run that starts no earlier than this call: a new one for an idle
    /// key, else the follow-up queued behind the key's run in progress.
    public func join(_ key: String) -> SupermuxSharedRun<Value> {
        lock.lock()
        defer { lock.unlock() }
        guard running[key] != nil else {
            let run = SupermuxSharedRun<Value>()
            running[key] = run
            start(run, for: key)
            return run
        }
        if let next = queued[key] { return next }
        let next = SupermuxSharedRun<Value>()
        queued[key] = next
        return next
    }

    private func start(_ run: SupermuxSharedRun<Value>, for key: String) {
        Thread.detachNewThread {
            let value = self.work(key)
            self.end(run, for: key)
            run.finish(value)
        }
    }

    /// The run ended: the follow-up, if any request queued one, starts now.
    private func end(_ run: SupermuxSharedRun<Value>, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard running[key] === run else { return }
        running[key] = queued.removeValue(forKey: key)
        if let next = running[key] { start(next, for: key) }
    }
}

/// One run; any number of requests wait for it.
public final class SupermuxSharedRun<Value: Sendable>: @unchecked Sendable {
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var value: Value?

    init() {
        finished.enter()
    }

    func finish(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
        finished.leave()
    }

    /// The run's value, or `nil` while it is still going (or has not started)
    /// after `seconds`.
    public func wait(seconds: TimeInterval) -> Value? {
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

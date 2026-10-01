public import Foundation

/// Blocking work per key (a folder's `git status`), shared by the requests
/// for that key so slow work never piles up.
///
/// A request for a key whose run is still going waits for that run instead of
/// starting another: a request that gives up at its bound leaves the work
/// running (`GitStatusProvider` cannot stop git), and the next request must
/// not add a second one.
///
/// ```swift
/// let runs = SupermuxSharedRuns<[String: GitFileStatus]> { root in GitStatusProvider().fetchStatus(directory: root) }
/// let statuses = runs.join(root).wait(seconds: 30)   // nil while still running
/// ```
public final class SupermuxSharedRuns<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: SupermuxSharedRun<Value>] = [:]
    private let queue: DispatchQueue
    private let work: @Sendable (String) -> Value

    /// - Parameters:
    ///   - queue: where each run executes.
    ///   - work: the blocking work for one key.
    public init(queue: DispatchQueue = .global(qos: .utility), work: @escaping @Sendable (String) -> Value) {
        self.queue = queue
        self.work = work
    }

    /// The key's run in progress, or a new one started now.
    public func join(_ key: String) -> SupermuxSharedRun<Value> {
        lock.lock()
        defer { lock.unlock() }
        if let run = running[key] { return run }
        let run = SupermuxSharedRun<Value>()
        running[key] = run
        queue.async {
            let value = self.work(key)
            self.end(run, for: key)
            run.finish(value)
        }
        return run
    }

    private func end(_ run: SupermuxSharedRun<Value>, for key: String) {
        lock.lock()
        if running[key] === run { running[key] = nil }
        lock.unlock()
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

    /// The run's value, or `nil` while it is still going after `seconds`.
    public func wait(seconds: TimeInterval) -> Value? {
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public import Foundation

/// A refresh that runs at most once at a time. A request made while a run is
/// in flight waits for one re-run that starts after that run ends, shared by
/// every request made meanwhile, so each caller gets an answer computed after
/// it asked and slow runs never pile up.
///
/// A mirror's Files panel asks for the other Mac's git colors on every live
/// change (up to once a second) while one `files.git_status` can take seconds
/// there. Every caller passes the same work; a re-run uses the first caller's.
///
/// ```swift
/// let colors = await gitColors.run { await transport.gitStatus() }
/// ```
public actor SupermuxCoalescedRefresh<Value: Sendable> {
    private var waiting: [CheckedContinuation<Value, Never>] = []
    private var isRunning = false

    public init() {}

    /// The value of a run that started after this call.
    public func run(_ work: @escaping @Sendable () async -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard !isRunning else { return }
            isRunning = true
            Task { await self.drain(work) }
        }
    }

    /// Runs `work` until no request is left waiting, answering each batch
    /// with the run that started after it queued.
    private func drain(_ work: @escaping @Sendable () async -> Value) async {
        while !waiting.isEmpty {
            let served = waiting
            waiting.removeAll()
            let value = await work()
            for continuation in served { continuation.resume(returning: value) }
        }
        isRunning = false
    }
}

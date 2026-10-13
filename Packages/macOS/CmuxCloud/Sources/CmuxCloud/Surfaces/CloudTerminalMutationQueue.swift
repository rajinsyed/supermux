import Foundation

// SUPERMUX:begin runtime-cloud-mutations-receipt-ownership
/// The queue and transport share one atomic cancellation/admission boundary.
/// Task-local propagation keeps it attached to the real link request, not a
/// detached response waiter. Admission never implies remote success or replay.
// The lock makes admission/cancellation one synchronous compare-and-set across task callbacks.
final class CloudCommittedMutationOwnership: @unchecked Sendable {
    @TaskLocal static var current: CloudCommittedMutationOwnership?

    private let lock = NSLock()
    private var cancelled = false
    private var admitted = false
    private var cancelOperation: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setCancellation(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldCancel = cancelled && !admitted
        if !cancelled && !admitted { cancelOperation = cancel }
        lock.unlock()
        if shouldCancel { cancel() }
    }

    func admit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled || admitted else { return false }
        admitted = true
        cancelOperation = nil
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let cancel = admitted ? nil : cancelOperation
        cancelOperation = nil
        lock.unlock()
        cancel?()
    }

    func finish() {
        lock.lock()
        cancelOperation = nil
        lock.unlock()
    }
}

// The lock arbitrates one continuation result between synchronous cancellation and completion.
private final class CloudCommittedMutationWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let result = self.result
            if result == nil { self.continuation = continuation }
            lock.unlock()
            if let result { continuation.resume(with: result) }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
// SUPERMUX:end runtime-cloud-mutations-receipt-ownership

/// Serializes one machine's terminal mutations across actor suspension points.
///
/// The daemon revision covers the whole machine, including other workspaces.
/// Every create keeps its turn through snapshot, mutation, and receipt handling.
@MainActor
public final class CloudTerminalMutationQueue {
    public nonisolated init() {}

    // SUPERMUX:begin runtime-cloud-mutations-intent-cancellation
    /// Whether the current mutation's caller or queue has cancelled its intent.
    public static var isCurrentTurnCancelled: Bool {
        Task.isCancelled || CloudCommittedMutationOwnership.current?.isCancelled == true
    }
    // SUPERMUX:end runtime-cloud-mutations-intent-cancellation

    private var tail: Task<Void, Never>?
    private var tailID: UUID?
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    /// Reserves an ordered turn synchronously, before the operation can suspend.
    /// A cancelled turn still waits for its predecessor before releasing successors.
    public func enqueue<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) -> Task<Value, Error> {
        let previous = tail
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { await previous.value }
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            return value
        }
        cancellations[id] = { task.cancel() }
        tailID = id
        tail = Task { @MainActor [weak self] in
            _ = try? await task.value
            self?.cancellations[id] = nil
            if self?.tailID == id {
                self?.tail = nil
                self?.tailID = nil
            }
        }
        return task
    }

    /// Invalidates every admitted turn but retains their ordering until active work drains.
    public func cancelAll() {
        for cancel in cancellations.values { cancel() }
    }

    /// Joins local admitted work through its bounded response lifetime.
    /// Timeout or transport loss leaves the remote outcome unknown; this does not promise rollback.
    public func waitForIdle() async {
        await tail?.value
    }

    /// Propagates caller cancellation without cancelling another intent's turn.
    public func run<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let task = enqueue(operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // SUPERMUX:begin runtime-cloud-mutations-committed-turn
    /// Cancels unsent work, or only the caller's wait after transport admission.
    /// The operation must adopt or compensate for its receipt; its ordered turn
    /// remains occupied until that bounded work completes.
    public func runCommitted<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let ownership = CloudCommittedMutationOwnership()
        let waiter = CloudCommittedMutationWaiter<Value>()
        _ = enqueueCommitted(operation, ownership: ownership, waiter: waiter)
        return try await withTaskCancellationHandler {
            try await waiter.value()
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
            ownership.cancel()
        }
    }

    private func enqueueCommitted<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value,
        ownership: CloudCommittedMutationOwnership,
        waiter: CloudCommittedMutationWaiter<Value>
    ) -> Task<Value, Error> {
        let previous = tail
        let id = UUID()
        let task = Task { @MainActor in
            defer { ownership.finish() }
            do {
                if let previous { await previous.value }
                try Task.checkCancellation()
                let value = try await CloudCommittedMutationOwnership.$current.withValue(ownership) {
                    try await operation()
                }
                waiter.resolve(.success(value))
                return value
            } catch {
                waiter.resolve(.failure(error))
                throw error
            }
        }
        ownership.setCancellation { task.cancel() }
        cancellations[id] = {
            waiter.resolve(.failure(CancellationError()))
            ownership.cancel()
        }
        tailID = id
        tail = Task { @MainActor [weak self] in
            _ = try? await task.value
            self?.cancellations[id] = nil
            if self?.tailID == id {
                self?.tail = nil
                self?.tailID = nil
            }
        }
        return task
    }
    // SUPERMUX:end runtime-cloud-mutations-committed-turn
}

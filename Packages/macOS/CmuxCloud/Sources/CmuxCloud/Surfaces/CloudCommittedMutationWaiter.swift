import Foundation

// SUPERMUX:begin runtime-cloud-mutations-waiter-arbitration
/// Resolves one committed mutation's caller without releasing its ordered turn.
// The lock arbitrates one continuation result between synchronous cancellation and completion.
final class CloudCommittedMutationWaiter<Value: Sendable>: @unchecked Sendable {
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
// SUPERMUX:end runtime-cloud-mutations-waiter-arbitration

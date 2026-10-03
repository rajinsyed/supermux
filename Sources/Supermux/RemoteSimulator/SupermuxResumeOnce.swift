import os

/// Resumes a continuation once, with whichever result comes first: an answer
/// raced against a deadline (``SupermuxCoreSimulatorDevices``,
/// ``SupermuxSimulatorDeviceListing``).
final class SupermuxResumeOnce<Value: Sendable, Failure: Error>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, Failure>?>

    init(_ continuation: CheckedContinuation<Value, Failure>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(with result: Result<Value, Failure>) {
        let pending = continuation.withLock { state -> CheckedContinuation<Value, Failure>? in
            defer { state = nil }
            return state
        }
        pending?.resume(with: result)
    }
}

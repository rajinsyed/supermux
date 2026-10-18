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
// SUPERMUX:end runtime-cloud-mutations-receipt-ownership

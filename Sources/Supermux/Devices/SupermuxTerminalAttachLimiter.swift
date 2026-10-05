import Foundation

/// Bounds how many hidden device mirrors re-attach at once after their link
/// reconnects (touchpoint `terminal-stream-attach-limiter`).
///
/// A reconnect (after sleep, a roam, the other Mac restarting) tells every
/// mirror on the link to re-attach in the same instant: each asks the other
/// Mac for a replay (a full one can be several MB), decodes it and parses it
/// into its surface, and the main thread stalled under all of them at once.
/// A mirror on screen still re-attaches at once; hidden ones wait here and go
/// at most ``maximumInFlight`` at a time, at utility priority. Every one of
/// them still re-attaches, and one shown while it waits goes at once.
@MainActor
final class SupermuxTerminalAttachLimiter {
    static let shared = SupermuxTerminalAttachLimiter()
    static let maximumInFlight = 3

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var inFlight = 0
    private var waiters: [Waiter] = []

    /// Runs `attach` once a slot is free and frees the slot when `attach`
    /// returns (its replay applied or failed). A cancelled wait runs nothing.
    func run(_ attach: () async -> Void) async {
        guard await acquire() else { return }
        if !Task.isCancelled { await attach() }
        release()
    }

    /// True once a slot is held; false when the wait was cancelled.
    private func acquire() async -> Bool {
        if inFlight < Self.maximumInFlight {
            inFlight += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in SupermuxTerminalAttachLimiter.shared.cancel(id) }
        }
    }

    /// Hands the slot straight to the oldest waiter, or frees it.
    private func release() {
        guard !waiters.isEmpty else {
            inFlight -= 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

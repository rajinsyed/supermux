#if DEBUG
import Foundation

/// A write into a pipe whose reader or writer already closed it.
enum SupermuxDeviceLoopbackPipeError: Error, Equatable {
    case closed
}

/// One direction of the DEBUG loopback device's in-process byte stream.
///
/// Byte-stream semantics, like a socket: writes append, a read returns every
/// byte buffered so far (both RPC endpoints re-frame their input, so chunk
/// boundaries carry no meaning), and a read on an empty pipe suspends until
/// the next write. After ``close()`` the remaining bytes still drain, then
/// reads return `nil` (end of stream) and writes throw.
actor SupermuxDeviceLoopbackPipe {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Data?, any Error>
    }

    private var buffered = Data()
    private var isClosed = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    func write(_ data: Data) throws {
        guard !isClosed else { throw SupermuxDeviceLoopbackPipeError.closed }
        guard !data.isEmpty else { return }
        // A reader only waits while the buffer is empty, so the first waiter
        // takes these bytes directly and ordering is preserved.
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: data)
        } else {
            buffered.append(data)
        }
    }

    func read() async throws -> Data? {
        if !buffered.isEmpty {
            let data = buffered
            buffered = Data()
            return data
        }
        if isClosed { return nil }
        try Task.checkCancellation()
        let id = nextWaiterID
        nextWaiterID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(returning: nil) }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
#endif

#if DEBUG
import Foundation

/// A write into a pipe whose reader or writer already closed it.
enum SupermuxDeviceLoopbackPipeError: Error, Equatable {
    case closed
}

/// Artificial one-way latency for the DEBUG loopback device, so E2E can type
/// over a "slow link" (`supermux.devices.terminal_input.latency`). Read by
/// each pipe write; zero (the default) delivers at once.
enum SupermuxDeviceLoopbackLatency {
    enum Direction: Sendable {
        /// The viewing Mac's requests to the loopback host.
        case toHost
        /// The loopback host's replies and events to the viewing Mac.
        case toViewer
    }

    nonisolated(unsafe) static var toHost: Duration = .zero
    nonisolated(unsafe) static var toViewer: Duration = .zero

    static func delay(_ direction: Direction) -> Duration {
        switch direction {
        case .toHost: toHost
        case .toViewer: toViewer
        }
    }
}

/// One direction of the DEBUG loopback device's in-process byte stream.
///
/// Byte-stream semantics, like a socket: writes append, a read returns every
/// byte buffered so far (both RPC endpoints re-frame their input, so chunk
/// boundaries carry no meaning), and a read on an empty pipe suspends until
/// the next write. After ``close()`` the remaining bytes still drain, then
/// reads return `nil` (end of stream) and writes throw.
///
/// With a ``SupermuxDeviceLoopbackLatency`` armed for its direction, each
/// write reaches the reader that much later, in order, as on a slow network
/// link. Bytes still in transit when the pipe closes are lost, as packets on
/// a dropped connection are.
actor SupermuxDeviceLoopbackPipe {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Data?, any Error>
    }

    /// The device link direction this pipe carries; nil (tunnel and
    /// simulator lanes) never gets the artificial latency.
    private let direction: SupermuxDeviceLoopbackLatency.Direction?
    private var buffered = Data()
    private var isClosed = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private var inTransit: [(due: ContinuousClock.Instant, data: Data)] = []
    private var transitTask: Task<Void, Never>?

    init(direction: SupermuxDeviceLoopbackLatency.Direction? = nil) {
        self.direction = direction
    }

    func write(_ data: Data) throws {
        guard !isClosed else { throw SupermuxDeviceLoopbackPipeError.closed }
        guard !data.isEmpty else { return }
        let delay = direction.map(SupermuxDeviceLoopbackLatency.delay) ?? .zero
        guard delay > .zero || !inTransit.isEmpty else {
            deliver(data)
            return
        }
        // Queued behind bytes still in transit even when the latency was just
        // turned off, so the stream never reorders.
        inTransit.append((due: ContinuousClock.now + delay, data: data))
        if transitTask == nil {
            transitTask = Task { await self.runTransit() }
        }
    }

    private func deliver(_ data: Data) {
        // A reader only waits while the buffer is empty, so the first waiter
        // takes these bytes directly and ordering is preserved.
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: data)
        } else {
            buffered.append(data)
        }
    }

    private func runTransit() async {
        while let next = inTransit.first {
            try? await Task.sleep(until: next.due, clock: .continuous)
            guard !isClosed, !inTransit.isEmpty else { break }
            deliver(inTransit.removeFirst().data)
        }
        transitTask = nil
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
        inTransit.removeAll()
        transitTask?.cancel()
        transitTask = nil
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

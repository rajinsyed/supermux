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
/// A device-link direction is a link that ``SupermuxDeviceLoopbackLatency``
/// and ``SupermuxDeviceLoopbackImpairment`` can slow down: written bytes wait
/// in a send buffer (a write waits while it is full), leave at the capped
/// rate, travel the one-way delay and arrive in order; nothing crosses during
/// a drop. Bytes still on their way when the pipe closes are lost, as packets
/// on a dropped connection are.
actor SupermuxDeviceLoopbackPipe {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Data?, any Error>
    }

    /// The device link direction this pipe carries; nil (tunnel and
    /// simulator lanes) never gets the artificial impairment.
    private let direction: SupermuxDeviceLoopbackLatency.Direction?
    private var buffered = Data()
    private var isClosed = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    /// Written bytes the link has not sent yet (its send buffer), in order.
    private var unsent: [Data] = []
    private var unsentBytes = 0
    /// Sent bytes on their way, arriving in order at `due`.
    private var inTransit: [(due: ContinuousClock.Instant, data: Data)] = []
    /// When the link finishes sending what it already took.
    private var linkFreeAt = ContinuousClock.now
    private var sendTask: Task<Void, Never>?
    private var transitTask: Task<Void, Never>?
    /// Writers waiting for room in the send buffer.
    private var roomWaiters: [CheckedContinuation<Void, Never>] = []

    init(direction: SupermuxDeviceLoopbackLatency.Direction? = nil) {
        self.direction = direction
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw SupermuxDeviceLoopbackPipeError.closed }
        guard !data.isEmpty else { return }
        guard let direction else {
            deliver(data)
            return
        }
        let shaping = SupermuxDeviceLoopbackImpairment.shaping(direction)
        // Queued behind bytes still on their way even when the impairment was
        // just turned off, so the stream never reorders.
        guard shaping.impairs || !unsent.isEmpty || !inTransit.isEmpty else {
            deliver(data)
            return
        }
        enqueue(data, chunked: shaping.bytesPerSecond > 0, direction: direction)
        if sendTask == nil {
            sendTask = Task { await self.runSend() }
        }
        // A full send buffer holds the writer, as a socket's does. The bytes
        // are already queued, so a waiting writer never reorders the stream.
        var waited = false
        while !isClosed, unsentBytes > SupermuxDeviceLoopbackImpairment.shaping(direction).queueBytes {
            if !waited {
                waited = true
                SupermuxDeviceLoopbackImpairment.noteWriteWaited(direction)
            }
            await withCheckedContinuation { roomWaiters.append($0) }
        }
    }

    private func enqueue(_ data: Data, chunked: Bool, direction: SupermuxDeviceLoopbackLatency.Direction) {
        let size = chunked ? SupermuxDeviceLoopbackImpairment.chunkBytes : data.count
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            unsent.append(data.subdata(in: offset..<end))
            offset = end
        }
        unsentBytes += data.count
        SupermuxDeviceLoopbackImpairment.noteQueued(direction, delta: data.count)
    }

    /// The link: sends the buffered chunks one after another at the capped
    /// rate, never during a drop, and puts each on its way.
    private func runSend() async {
        while !isClosed, let chunk = unsent.first, let direction {
            let shaping = SupermuxDeviceLoopbackImpairment.shaping(direction)
            var start = max(ContinuousClock.now, linkFreeAt)
            if let dropEnd = SupermuxDeviceLoopbackImpairment.dropEnd(at: start) { start = dropEnd }
            let sending: Duration = shaping.bytesPerSecond > 0
                ? .seconds(Double(chunk.count) / Double(shaping.bytesPerSecond))
                : .zero
            let sent = start + sending
            if sent > .now { try? await Task.sleep(until: sent, clock: .continuous) }
            guard !isClosed, !unsent.isEmpty else { break }
            linkFreeAt = sent
            unsent.removeFirst()
            unsentBytes -= chunk.count
            SupermuxDeviceLoopbackImpairment.noteQueued(direction, delta: -chunk.count)
            resumeRoomWaiters()
            inTransit.append((due: sent + shaping.delay, data: chunk))
            if transitTask == nil {
                transitTask = Task { await self.runTransit() }
            }
        }
        sendTask = nil
    }

    /// The wire: each sent chunk arrives after its delay, in order; one on
    /// its way when a drop starts arrives once the drop ends.
    private func runTransit() async {
        while !isClosed, let next = inTransit.first {
            if next.due > .now { try? await Task.sleep(until: next.due, clock: .continuous) }
            while !isClosed, let dropEnd = SupermuxDeviceLoopbackImpairment.dropEnd(at: .now) {
                try? await Task.sleep(until: dropEnd, clock: .continuous)
            }
            guard !isClosed, !inTransit.isEmpty else { break }
            deliver(inTransit.removeFirst().data)
        }
        transitTask = nil
    }

    private func resumeRoomWaiters() {
        let waiting = roomWaiters
        roomWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private func deliver(_ data: Data) {
        if let direction { SupermuxDeviceLoopbackImpairment.noteDelivered(direction, bytes: data.count) }
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
        if let direction, unsentBytes > 0 {
            SupermuxDeviceLoopbackImpairment.noteQueued(direction, delta: -unsentBytes)
        }
        unsent.removeAll()
        unsentBytes = 0
        inTransit.removeAll()
        sendTask?.cancel()
        sendTask = nil
        transitTask?.cancel()
        transitTask = nil
        resumeRoomWaiters()
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

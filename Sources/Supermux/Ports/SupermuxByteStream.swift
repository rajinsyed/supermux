import CmuxIrxTransport
import Foundation
import Network

/// One TCP-like byte stream that port forwarding relays: a tunnel lane to
/// another Mac (`IrxLaneStream`), a local TCP connection
/// (``SupermuxNWConnectionStream``), or the DEBUG loopback device's in-memory
/// lane. Every call suspends until it is done, so a relay that reads its next
/// chunk only after writing the previous one never buffers more than a chunk.
protocol SupermuxByteStream: Sendable {
    /// The next chunk of at most `maximumByteCount` bytes, or nil at end of stream.
    func readRaw(maximumByteCount: Int) async throws -> Data?
    func write(_ data: Data) async throws
    /// Half-closes our sending side (TCP FIN).
    func finish() async
    /// Aborts both directions.
    func abort() async
}

/// The lane's methods are already public through `IrxTunnelLane`.
extension IrxLaneStream: SupermuxByteStream {}

/// Rewrites one direction of a relay as it passes, for example the HTTP
/// request and response headers of a browser proxy. Called once per chunk in
/// order, then once with empty data and `eof` true to flush what it held back.
protocol SupermuxByteTransform: AnyObject, Sendable {
    func transform(_ data: Data, eof: Bool) -> Data
}

/// Why a local TCP connection did not become ready.
enum SupermuxNWConnectionError: Error, Equatable {
    case failed(String)
    case timedOut
    case cancelled
}

/// An `NWConnection` behind async calls: a connection a forward or proxy
/// listener accepted, or one it dialed.
final class SupermuxNWConnectionStream: SupermuxByteStream, @unchecked Sendable {
    private let connection: NWConnection

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Starts a connection an `NWListener` handed over and waits until it is ready.
    static func accepted(_ connection: NWConnection, timeout: Duration = .seconds(5)) async throws -> SupermuxNWConnectionStream {
        try await start(connection, timeout: timeout)
        return SupermuxNWConnectionStream(connection: connection)
    }

    /// Dials `host:port` (a name or an IP literal) from this Mac.
    static func connect(host: String, port: Int, timeout: Duration = .seconds(10)) async throws -> SupermuxNWConnectionStream {
        guard (1...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw SupermuxNWConnectionError.failed("invalid port")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        try await start(connection, timeout: timeout)
        return SupermuxNWConnectionStream(connection: connection)
    }

    /// Starts `connection` and waits for `.ready`; a refusal (`.waiting`),
    /// failure, cancellation or the deadline cancels it and throws.
    private static func start(_ connection: NWConnection, timeout: Duration) async throws {
        let outcome = ReadyOutcome()
        let deadline = Task {
            try await Task.sleep(for: timeout)
            outcome.finish(.timedOut)
        }
        defer { deadline.cancel() }
        let failure = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SupermuxNWConnectionError?, Never>) in
                outcome.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        outcome.finish(nil)
                    case .waiting(let error), .failed(let error):
                        outcome.finish(.failed(String(describing: error)))
                    case .cancelled:
                        outcome.finish(.cancelled)
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "dev.supermux.ports.connection"))
            }
        } onCancel: {
            outcome.finish(.cancelled)
        }
        connection.stateUpdateHandler = nil
        if let failure {
            connection.cancel()
            throw failure
        }
    }

    func readRaw(maximumByteCount: Int) async throws -> Data? {
        while true {
            let chunk = try await receiveOnce(maximumByteCount: maximumByteCount)
            if chunk?.isEmpty != true { return chunk }
        }
    }

    private func receiveOnce(maximumByteCount: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximumByteCount)) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func abort() async {
        connection.cancel()
    }

    /// Resumes the start continuation exactly once, from whichever of state
    /// change, deadline or cancellation comes first.
    private final class ReadyOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<SupermuxNWConnectionError?, Never>?
        private var settled: SupermuxNWConnectionError??

        func install(_ continuation: CheckedContinuation<SupermuxNWConnectionError?, Never>) {
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(returning: settled)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: SupermuxNWConnectionError?) {
            lock.lock()
            guard settled == nil else {
                lock.unlock()
                return
            }
            settled = .some(result)
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}

/// Relays two byte streams into each other, as a forward relays a local
/// connection into a tunnel.
enum SupermuxByteStreamPump {
    /// Copies both ways, one chunk in flight per direction (backpressure); EOF on one
    /// side finish()es the other; an error aborts both. Returns when both directions end.
    static func run(_ local: any SupermuxByteStream, _ remote: any SupermuxByteStream,
                    localToRemote: (any SupermuxByteTransform)? = nil,
                    remoteToLocal: (any SupermuxByteTransform)? = nil,
                    chunkByteCount: Int = 64 * 1024) async {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await copy(from: local, to: remote, transform: localToRemote, chunkByteCount: chunkByteCount)
                }
                group.addTask {
                    await copy(from: remote, to: local, transform: remoteToLocal, chunkByteCount: chunkByteCount)
                }
                var aborted = false
                for await clean in group where !clean && !aborted {
                    aborted = true
                    await local.abort()
                    await remote.abort()
                }
            }
        } onCancel: {
            Task {
                await local.abort()
                await remote.abort()
            }
        }
    }

    /// One direction: false when it ended in an error.
    private static func copy(
        from source: any SupermuxByteStream,
        to destination: any SupermuxByteStream,
        transform: (any SupermuxByteTransform)?,
        chunkByteCount: Int
    ) async -> Bool {
        do {
            while let chunk = try await source.readRaw(maximumByteCount: chunkByteCount) {
                try Task.checkCancellation()
                let out = transform?.transform(chunk, eof: false) ?? chunk
                if !out.isEmpty { try await destination.write(out) }
            }
            if let tail = transform?.transform(Data(), eof: true), !tail.isEmpty {
                try await destination.write(tail)
            }
            await destination.finish()
            return true
        } catch {
            return false
        }
    }
}

/// The ports this app itself listens on for port forwards and browser proxies.
/// The tunnel host refuses them (``SupermuxLoopGuardConnector``), so a forward
/// never tunnels into another forward, and `ports.list` never offers them.
/// Counted: a port registered twice (one listener per address family) stays
/// registered until it is removed twice.
final class SupermuxOwnListenerPorts: @unchecked Sendable {
    static let shared = SupermuxOwnListenerPorts()

    private let lock = NSLock()
    private var counts: [Int: Int] = [:]

    func insert(_ port: Int) {
        lock.lock()
        defer { lock.unlock() }
        counts[port, default: 0] += 1
    }

    func remove(_ port: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let count = counts[port] else { return }
        counts[port] = count > 1 ? count - 1 : nil
    }

    func contains(_ port: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return counts[port] != nil
    }

    /// Every registered port.
    var all: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(counts.keys)
    }
}

#if DEBUG
import CmuxIrxTransport
import Foundation

/// One in-memory `tcp_connect` lane of the DEBUG loopback device, so the real
/// `IrxTunnelHost` (policy, limits, Network.framework connector) serves the
/// loopback link's tunnels in-process: the loopback has no irx connection, so
/// no `IrxLaneStream` exists to hand the host.
///
/// Two ``SupermuxDeviceLoopbackPipe``s carry the lane: `up` (client to host)
/// and `down` (host to client). The host's first frame on `down` is the
/// `IrxTunnelOpenReply` (4-byte big-endian length + JSON, `IrxFrameCodec`),
/// then raw bytes both ways, as on a QUIC lane. An abort on either half
/// closes both pipes and makes both halves' reads throw (a QUIC reset), not
/// end cleanly. The pipes have no flow control: unlike QUIC, a fast writer
/// buffers in memory.
enum SupermuxDeviceLoopbackTunnelLane {
    /// A lane to `host:port`: the half the tunnel host serves and the half the
    /// viewer reads and writes.
    static func pair(host: String, port: Int) -> (HostHalf, ClientHalf) {
        let up = SupermuxDeviceLoopbackPipe()
        let down = SupermuxDeviceLoopbackPipe()
        let reset = ResetFlag()
        let descriptor = IrxLaneDescriptor(lane: .tcpConnect, host: host, port: port)
        return (
            HostHalf(descriptor: descriptor, inbound: up, outbound: down, reset: reset),
            ClientHalf(inbound: down, outbound: up, reset: reset)
        )
    }

    /// The tunnel host's view of the lane.
    actor HostHalf: IrxTunnelLane {
        nonisolated let descriptor: IrxLaneDescriptor
        private let reader: Reader
        private let outbound: SupermuxDeviceLoopbackPipe
        private let reset: ResetFlag

        init(
            descriptor: IrxLaneDescriptor,
            inbound: SupermuxDeviceLoopbackPipe,
            outbound: SupermuxDeviceLoopbackPipe,
            reset: ResetFlag
        ) {
            self.descriptor = descriptor
            reader = Reader(pipe: inbound, reset: reset)
            self.outbound = outbound
            self.reset = reset
        }

        func readRaw(maximumByteCount: Int) async throws -> Data? {
            try await reader.next(maximumByteCount: maximumByteCount)
        }

        func write(_ data: Data) async throws {
            try await outbound.write(data)
        }

        func writeFrame(_ value: some Encodable & Sendable) async throws {
            try await outbound.write(IrxFrameCodec().encode(value))
        }

        func finish() async {
            await outbound.close()
        }

        func abort() async {
            await reset.abort(closing: reader.pipe, outbound)
        }
    }

    /// The viewer's view of the lane: the open reply, then raw bytes.
    actor ClientHalf {
        private let reader: Reader
        private let outbound: SupermuxDeviceLoopbackPipe
        private let reset: ResetFlag

        init(inbound: SupermuxDeviceLoopbackPipe, outbound: SupermuxDeviceLoopbackPipe, reset: ResetFlag) {
            reader = Reader(pipe: inbound, reset: reset)
            self.outbound = outbound
            self.reset = reset
        }

        /// The host's `IrxTunnelOpenReply`, as `IrxTunnelClient.connect` reads
        /// it: a missing, malformed or late reply aborts the lane and throws
        /// `IrxTunnelOpenError(.failed)`.
        func readReply(timeout: Duration) async throws -> IrxTunnelOpenReply {
            let deadline = Task { [weak self] in
                try await Task.sleep(for: timeout)
                await self?.abort()
            }
            defer { deadline.cancel() }
            do {
                guard let header = try await reader.exactly(4) else { throw IrxTunnelOpenError(status: .failed) }
                let length = header.reduce(0) { $0 << 8 | Int($1) }
                guard length <= IrxProtocol().maximumControlFrameByteCount,
                      let body = try await reader.exactly(length) else { throw IrxTunnelOpenError(status: .failed) }
                return try IrxFrameCodec().decode(IrxTunnelOpenReply.self, from: body)
            } catch {
                await abort()
                throw IrxTunnelOpenError(status: .failed)
            }
        }

        func readRaw(maximumByteCount: Int) async throws -> Data? {
            try await reader.next(maximumByteCount: maximumByteCount)
        }

        func write(_ data: Data) async throws {
            try await outbound.write(data)
        }

        /// Half-closes the viewer's sending side.
        func finish() async {
            await outbound.close()
        }

        func abort() async {
            await reset.abort(closing: reader.pipe, outbound)
        }
    }

    /// Buffered reads from one pipe: a pipe read returns every byte written so
    /// far, so the rest of a chunk waits here for the next read.
    actor Reader {
        nonisolated let pipe: SupermuxDeviceLoopbackPipe
        private let reset: ResetFlag
        private var leftover = Data()

        init(pipe: SupermuxDeviceLoopbackPipe, reset: ResetFlag) {
            self.pipe = pipe
            self.reset = reset
        }

        /// At most `maximumByteCount` bytes, or nil at end of stream; throws
        /// once the lane was aborted.
        func next(maximumByteCount: Int) async throws -> Data? {
            if leftover.isEmpty {
                guard let chunk = try await pipe.read() else {
                    if reset.isAborted { throw SupermuxDeviceLoopbackPipeError.closed }
                    return nil
                }
                leftover = chunk
            }
            let count = min(max(1, maximumByteCount), leftover.count)
            let head = Data(leftover.prefix(count))
            leftover = Data(leftover.dropFirst(count))
            return head
        }

        /// Exactly `count` bytes, or nil when the stream ends first.
        func exactly(_ count: Int) async throws -> Data? {
            var collected = Data()
            while collected.count < count {
                guard let chunk = try await next(maximumByteCount: count - collected.count) else { return nil }
                collected.append(chunk)
            }
            return collected
        }
    }

    /// Shared by both halves: set by either half's abort, so the other half's
    /// reads fail instead of ending cleanly.
    final class ResetFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var aborted = false

        var isAborted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return aborted
        }

        func abort(closing pipes: SupermuxDeviceLoopbackPipe...) async {
            markAborted()
            for pipe in pipes { await pipe.close() }
        }

        private func markAborted() {
            lock.lock()
            defer { lock.unlock() }
            aborted = true
        }
    }
}
#endif

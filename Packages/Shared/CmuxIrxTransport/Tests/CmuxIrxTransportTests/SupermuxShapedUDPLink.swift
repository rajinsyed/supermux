// SUPERMUX:begin irx-shaped-udp-link (whole-file fork test helper: a shaped UDP relay for live QUIC tests — see SUPERMUX-TOUCHPOINTS.md)
import Darwin
import Foundation

/// A slow network path for live QUIC tests: a UDP relay on 127.0.0.1 between
/// a client endpoint and a host endpoint that carries each datagram after a
/// one-way delay and at a capped rate, through a bounded queue that drops
/// what does not fit, as a congested router does. QUIC's congestion control
/// then settles on the cap, so the sender's own scheduler decides which
/// stream's buffered data goes out first, as on a capacity-limited relay.
///
/// The client dials ``clientFacingAddress`` instead of the host; the relay
/// forwards to `hostPort` from its own host-facing socket, so the host
/// answers the relay. Both directions get the same shaping.
final class SupermuxShapedUDPLink: @unchecked Sendable {
    struct Shape: Sendable {
        var bytesPerSecond: Double
        var oneWayDelay: TimeInterval
        var queueBytes: Double
    }

    private struct Datagram {
        let arrivesAt: TimeInterval
        let data: [UInt8]
    }

    /// One direction's bottleneck: when it is free again, and what crosses it.
    private struct Direction {
        var linkFreeAt: TimeInterval = 0
        var inFlight: [Datagram] = []
        var dropped = 0
    }

    let clientFacingAddress: String
    private let shape: Shape
    private let clientSide: Int32
    private let hostSide: Int32
    private var hostAddress: sockaddr_in
    private var clientAddress: sockaddr_in?
    private var toHost = Direction()
    private var toClient = Direction()
    private let lock = NSLock()
    private var running = true
    private var dropsEverything = false
    private var thread: Thread?

    init(hostPort: UInt16, shape: Shape) throws {
        self.shape = shape
        let client = try Self.bindLoopbackUDP()
        let host = try Self.bindLoopbackUDP()
        clientSide = client.socket
        hostSide = host.socket
        clientFacingAddress = "127.0.0.1:\(client.port)"
        hostAddress = Self.loopbackAddress(port: hostPort)
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "SupermuxShapedUDPLink"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    deinit { stop() }

    /// Datagrams the bounded queue dropped toward the client.
    var droppedToClient: Int { lock.withLock { toClient.dropped } }

    /// While true the path is cut: every datagram either way is dropped, as
    /// on a blocked or vanished network path. QUIC sees silence, not a close.
    var blocked: Bool {
        get { lock.withLock { dropsEverything } }
        set { lock.withLock { dropsEverything = newValue } }
    }

    /// Ends the relay; its thread polls in short slices and closes the sockets itself.
    func stop() {
        lock.withLock { running = false }
    }

    // MARK: - Relay thread

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while lock.withLock({ running }) {
            var fds = [
                pollfd(fd: clientSide, events: Int16(POLLIN), revents: 0),
                pollfd(fd: hostSide, events: Int16(POLLIN), revents: 0),
            ]
            _ = poll(&fds, 2, Int32(pollTimeoutMilliseconds()))
            if fds[0].revents & Int16(POLLIN) != 0 { receive(from: clientSide, into: &buffer, towardHost: true) }
            if fds[1].revents & Int16(POLLIN) != 0 { receive(from: hostSide, into: &buffer, towardHost: false) }
            sendDue()
        }
        close(clientSide)
        close(hostSide)
    }

    private func pollTimeoutMilliseconds() -> Int {
        let now = Self.now()
        let next = lock.withLock { [toHost.inFlight.first?.arrivesAt, toClient.inFlight.first?.arrivesAt].compactMap { $0 }.min() }
        guard let next else { return 5 }
        return max(0, min(5, Int(((next - now) * 1000).rounded(.up))))
    }

    private func receive(from socket: Int32, into buffer: inout [UInt8], towardHost: Bool) {
        while true {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socket, raw.baseAddress, raw.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard count > 0 else { return }
            let data = Array(buffer[0..<count])
            lock.withLock {
                guard !dropsEverything else { return }
                if towardHost {
                    clientAddress = source
                    Self.admit(data, into: &toHost, shape: shape)
                } else {
                    Self.admit(data, into: &toClient, shape: shape)
                }
            }
        }
    }

    /// Queues a datagram behind the ones still waiting for the link, or drops
    /// it when the queue is full.
    private static func admit(_ data: [UInt8], into direction: inout Direction, shape: Shape) {
        let now = now()
        let backlog = max(0, direction.linkFreeAt - now) * shape.bytesPerSecond
        guard backlog + Double(data.count) <= shape.queueBytes else {
            direction.dropped += 1
            return
        }
        let departs = max(now, direction.linkFreeAt) + Double(data.count) / shape.bytesPerSecond
        direction.linkFreeAt = departs
        direction.inFlight.append(Datagram(arrivesAt: departs + shape.oneWayDelay, data: data))
    }

    private func sendDue() {
        let now = Self.now()
        let (towardHost, towardClient, client) = lock.withLock { () -> ([Datagram], [Datagram], sockaddr_in?) in
            (Self.takeDue(&toHost, now: now), Self.takeDue(&toClient, now: now), clientAddress)
        }
        var host = hostAddress
        for datagram in towardHost { Self.send(datagram.data, from: hostSide, to: &host) }
        guard var client else { return }
        for datagram in towardClient { Self.send(datagram.data, from: clientSide, to: &client) }
    }

    private static func takeDue(_ direction: inout Direction, now: TimeInterval) -> [Datagram] {
        guard let index = direction.inFlight.firstIndex(where: { $0.arrivesAt > now }) else {
            defer { direction.inFlight.removeAll() }
            return direction.inFlight
        }
        defer { direction.inFlight.removeFirst(index) }
        return Array(direction.inFlight[0..<index])
    }

    private static func send(_ data: [UInt8], from socket: Int32, to address: inout sockaddr_in) {
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Sockets

    private struct SocketError: Error {
        let call: String
        let code: Int32
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func bindLoopbackUDP() throws -> (socket: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SocketError(call: "bind", code: errno) }
        var bufferSize: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw SocketError(call: "getsockname", code: errno) }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}
// SUPERMUX:end irx-shaped-udp-link

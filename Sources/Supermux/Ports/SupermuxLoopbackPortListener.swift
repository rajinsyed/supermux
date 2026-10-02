import CmuxSurfaceCatalogModel
import Foundation
import Network

/// One forwarded port on this Mac: a listener on port `L` of the loopback
/// interface (`127.0.0.1:L` and `[::1]:L`) that carries every accepted
/// connection through a tunnel to `localhost:P` on another Mac
/// (``SupermuxDeviceTunnelClient``), the way `ssh -L` does.
///
/// Modelled on `CloudLoopbackPortForward`, with a fixed port: the remote port
/// itself when it is free here, so a browser, the iOS Simulator or any other
/// app reaches `localhost:3000` exactly as on the owning Mac. Never sets
/// `allowLocalEndpointReuse`, and ``open(machine:remotePort:candidates:)``
/// probes every candidate first (``SupermuxLocalPortProbe``), so a port in use
/// here is never taken. Scoped to the loopback interface: nothing on the
/// network, nor this Mac's own LAN address, reaches it.
actor SupermuxLoopbackPortListener {
    /// How a bind attempt on one port ended.
    enum BindOutcome: Equatable {
        case bound(Int)
        /// The port is taken (by either address family); try the next one.
        case inUse
        case failed(String)
    }

    nonisolated let machine: SurfaceMachineID
    nonisolated let remotePort: Int
    /// The bound local port; 0 until bound.
    private(set) var port = 0
    private var listener: Listener?
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    private let queue = DispatchQueue(label: "dev.supermux.ports.forward", qos: .userInitiated)

    init(machine: SurfaceMachineID, remotePort: Int) {
        self.machine = machine
        self.remotePort = remotePort
    }

    /// Binds the first candidate port that is free on both loopback
    /// addresses, else an ephemeral one, and returns the bound port. Nil when
    /// nothing could be bound.
    static func open(
        machine: SurfaceMachineID, remotePort: Int, candidates: [Int]
    ) async -> (listener: SupermuxLoopbackPortListener, port: Int)? {
        for candidate in candidates + [0, 0, 0] {
            if candidate != 0 {
                guard !SupermuxOwnListenerPorts.shared.contains(candidate) else { continue }
                let inUse = await SupermuxLocalPortProbe.isInUse(candidate)
                guard !inUse else { continue }
            }
            let listener = SupermuxLoopbackPortListener(machine: machine, remotePort: remotePort)
            if case .bound(let port) = await listener.bind(port: candidate) { return (listener, port) }
        }
        return nil
    }

    /// Binds `port` (0 = any) on the loopback interface, IPv4 and IPv6 alike.
    ///
    /// One dual-stack listener, not one per address: Network.framework
    /// refuses `[::1]:P` while this process holds `127.0.0.1:P` (and the
    /// reverse) with EADDRINUSE, so a v4 + v6 pair never binds. This listener
    /// fails with EADDRINUSE whenever anything here listens on the port: either
    /// loopback address, a wildcard or dual-stack socket, or a LAN address.
    func bind(port requested: Int) async -> BindOutcome {
        let listener: Listener
        do {
            listener = try Listener(port: requested, queue: queue)
        } catch {
            return .failed(String(describing: error))
        }
        listener.onConnection = { [weak self] connection in Task { await self?.accept(connection) } }
        switch await listener.start() {
        case .ready(let bound):
            self.listener = listener
            port = bound
            SupermuxOwnListenerPorts.shared.insert(bound)
            return .bound(bound)
        case .failed(let code):
            return code == EADDRINUSE ? .inUse : .failed("bind failed (\(code ?? 0))")
        }
    }

    /// Stops accepting and ends every relayed connection. Returns once the
    /// listener released the port, so the caller can rely on it being free.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        let listener = self.listener
        self.listener = nil
        await listener?.stop()
        if port != 0 { SupermuxOwnListenerPorts.shared.remove(port) }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        let machine = machine
        let remotePort = remotePort
        Task { [weak self] in
            do {
                let local = try await SupermuxNWConnectionStream.accepted(connection)
                let remote = try await SupermuxDeviceTunnelClient.open(machine: machine, port: remotePort)
                await SupermuxByteStreamPump.run(local, remote)
            } catch {
                // The owner refused or is unreachable: close the local side, as
                // a server that is not listening would.
            }
            connection.cancel()
            await self?.connectionEnded(id)
        }
    }

    private func connectionEnded(_ id: UUID) {
        connections[id] = nil
    }
}

extension SupermuxLoopbackPortListener {
    /// One `NWListener` with async start and stop.
    final class Listener: @unchecked Sendable {
        enum StartResult {
            case ready(Int)
            /// The POSIX error, when the failure carried one.
            case failed(Int32?)
        }

        private let listener: NWListener
        private let queue: DispatchQueue
        private let lock = NSLock()
        private var startWaiter: CheckedContinuation<StartResult, Never>?
        private var startResult: StartResult?
        private var ended = false
        private var endWaiters: [CheckedContinuation<Void, Never>] = []
        var onConnection: (@Sendable (NWConnection) -> Void)?

        /// A dual-stack listener on `port` (0 = any) of the loopback interface.
        init(port: Int, queue: DispatchQueue) throws {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(
                using: parameters,
                on: port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
            )
            self.queue = queue
        }

        /// Starts listening; returns the bound port, or why it failed (the
        /// listener is then already cancelled).
        func start() async -> StartResult {
            listener.newConnectionHandler = { [weak self] connection in
                guard let handler = self?.onConnection else {
                    connection.cancel()
                    return
                }
                handler(connection)
            }
            let listener = self.listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.settleStart(.ready(Int(listener.port?.rawValue ?? 0)))
                case .waiting(let error):
                    // Address in use, for one: give the port back.
                    self.settleStart(.failed(Self.posixCode(error)))
                    listener.cancel()
                case .failed(let error):
                    // A failed listener holds no port.
                    self.settleStart(.failed(Self.posixCode(error)))
                    self.markEnded()
                    listener.cancel()
                case .cancelled:
                    self.settleStart(.failed(nil))
                    self.markEnded()
                default:
                    break
                }
            }
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<StartResult, Never>) in
                lock.lock()
                startWaiter = continuation
                lock.unlock()
                listener.start(queue: queue)
            }
            if case .failed = result { await stop() }
            return result
        }

        /// Cancels the listener and waits until it released its port.
        func stop() async {
            listener.newConnectionHandler = nil
            listener.cancel()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if ended {
                    lock.unlock()
                    continuation.resume()
                } else {
                    endWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        private func settleStart(_ result: StartResult) {
            lock.lock()
            guard startResult == nil else {
                lock.unlock()
                return
            }
            startResult = result
            let waiter = startWaiter
            startWaiter = nil
            lock.unlock()
            waiter?.resume(returning: result)
        }

        private func markEnded() {
            lock.lock()
            ended = true
            let waiters = endWaiters
            endWaiters = []
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        }

        private static func posixCode(_ error: NWError) -> Int32? {
            if case .posix(let code) = error { return code.rawValue }
            return nil
        }
    }
}

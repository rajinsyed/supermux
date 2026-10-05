import CMUXMobileCore
import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// Terminal output must not starve liveness and control on a link whose
/// capacity it fills (the remote-terminal delay of 2026-10-05).
///
/// noq sends a strictly higher-priority stream's buffered data first. The host
/// writes terminal output at priority 50 (every unfocused surface lane,
/// ``IrxSurfaceEventLanes/Configuration/backgroundPriority``, and the shared
/// events lane Mac mirrors use) and 100 (the focused surface), while the
/// keepalive pong (``IrxConnection/respondKeepalive(on:)``) and every control
/// reply (``IrxControlByteTransport``) stay at the default 0. Whenever the
/// path is the bottleneck (a relay at 240–400 ms), each packet the congestion
/// window allows carries output, so pongs and replies wait as long as output
/// keeps coming. In the field the viewer then missed its reply deadlines, its
/// liveness probe after them failed too, and it redialed a link that was
/// carrying bytes the whole time, about 45 times an hour.
///
/// Two real Iroh endpoints talk through ``SupermuxShapedUDPLink``: 300 KB/s
/// each way, 50 ms one way, a 64 KB queue that drops the rest, so QUIC's
/// congestion control (not flow control, which only gates writes) is the
/// limit, as on a relay. The host writes output continuously on a background
/// surface lane and the client reads it as fast as it arrives. A baseline
/// without output first proves the harness answers fast; then, with the
/// path saturated:
/// - a keepalive probe must be answered within 2 s (the protocol's own
///   keepalive deadline);
/// - a control request must be answered within 2 s.
/// Both fail today: the pong and the reply sit at priority 0 behind output at 50.
@Suite("stream priority on a capacity-limited path", .serialized)
struct SupermuxIrxPriorityStarvationTests {
    static let outputPriority = IrxSurfaceEventLanes.Configuration().backgroundPriority
    static let deadline: Duration = .seconds(2)

    @Test("a keepalive ping is answered while terminal output fills the path", .timeLimit(.minutes(1)))
    func keepaliveAnsweredWhileOutputFillsThePath() async throws {
        let pair = try await StarvedPair.make()
        let baseline = await pair.client.probeLiveness(deadline: Self.deadline)
        #expect(baseline, "the harness must answer a probe before any output flows")

        try await pair.startOutput()
        let started = ContinuousClock.now
        let answered = await pair.client.probeLiveness(deadline: Self.deadline)
        let waited = ContinuousClock.now - started
        let read = await pair.reader.bytesRead
        #expect(
            answered,
            "keepalive probe unanswered after \(waited) while output at priority \(Self.outputPriority) filled the path (\(read) output bytes read)"
        )
        await pair.shutDown()
    }

    @Test("a control request is answered while terminal output fills the path", .timeLimit(.minutes(1)))
    func controlRequestAnsweredWhileOutputFillsThePath() async throws {
        let pair = try await StarvedPair.make()
        let baseline = try await pair.controlRoundTrip(timeout: Self.deadline)
        #expect(baseline != nil, "the harness must answer a control request before any output flows")

        try await pair.startOutput()
        let roundTrip = try await pair.controlRoundTrip(timeout: .seconds(8))
        let read = await pair.reader.bytesRead
        if let roundTrip {
            #expect(
                roundTrip <= Self.deadline,
                "control round trip took \(roundTrip) while output at priority \(Self.outputPriority) filled the path (\(read) output bytes read)"
            )
        } else {
            Issue.record(
                "control request unanswered after 8 s while output at priority \(Self.outputPriority) filled the path (\(read) output bytes read)"
            )
        }
        await pair.shutDown()
    }
}

/// Counts the output lane's bytes as the client reads them.
private actor ReadCounter {
    private(set) var bytesRead = 0
    func add(_ count: Int) { bytesRead += count }
}

/// An admitted client/host pair over a shaped path, whose host can flood an
/// output lane.
private final class StarvedPair: Sendable {
    static let shape = SupermuxShapedUDPLink.Shape(bytesPerSecond: 300_000, oneWayDelay: 0.05, queueBytes: 64 * 1024)
    /// Output read before a check: the path is saturated and the host's send
    /// buffer holds a backlog.
    static let saturatedBytes = 256 * 1024
    static let outputFrame = Data(repeating: 0x61, count: 16 * 1024)

    let server: Endpoint
    let clientEndpoint: Endpoint
    let link: SupermuxShapedUDPLink
    let client: IrxConnection
    let host: IrxConnection
    let clientControl: IrxControlByteTransport
    let hostControl: IrxControlByteTransport
    let reader = ReadCounter()
    private let tasks = TaskBag()

    private init(
        server: Endpoint, clientEndpoint: Endpoint, link: SupermuxShapedUDPLink, client: IrxConnection,
        host: IrxConnection, clientControl: IrxControlByteTransport, hostControl: IrxControlByteTransport
    ) {
        self.server = server
        self.clientEndpoint = clientEndpoint
        self.link = link
        self.client = client
        self.host = host
        self.clientControl = clientControl
        self.hostControl = hostControl
    }

    /// Direct paths stay unauthorized (no NAT traversal is ever authorized),
    /// so the only path is the shaped one.
    private static func bind() async throws -> Endpoint {
        try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            bindAddr: "127.0.0.1:0",
            secretKey: IrxLiveTestSupport.identitySeed(),
            alpns: [IrxProtocol().alpnData],
            relayMode: RelayMode.disabled(),
            portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 8,
            initialMaxConcurrentUniStreams: 8
        ))
    }

    private static func port(of endpoint: Endpoint) throws -> UInt16 {
        let port = endpoint.boundSockets().lazy
            .compactMap { $0.split(separator: ":").last.flatMap { UInt16($0) } }
            .first
        return try #require(port, "the host endpoint has no bound UDP port: \(endpoint.boundSockets())")
    }

    static func make() async throws -> StarvedPair {
        let journal = IrxLiveTestSupport.journal()
        let server = try await bind()
        let clientEndpoint = try await bind()
        let link = try SupermuxShapedUDPLink(hostPort: try port(of: server), shape: shape)
        let serverTask = Task { () -> (IrxConnection, IrxLaneStream)? in
            guard let incoming = await server.acceptNext() else { return nil }
            let native = try await incoming.accept().connect()
            let irx = IrxConnection(connection: native, role: .acceptor, journal: journal)
            guard let (_, control, _) = await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            ) else { return nil }
            return (irx, control)
        }
        let native = try await clientEndpoint.connect(
            addr: EndpointAddr(id: server.id(), relayUrl: nil, addresses: [link.clientFacingAddress]),
            alpn: IrxProtocol().alpnData
        )
        let client = IrxConnection(connection: native, role: .dialer, journal: journal)
        let (_, clientLane) = try await IrxAdmission().performClient(
            connection: client, grantJWS: "good-grant", journal: journal)
        let (host, hostLane) = try #require(try await serverTask.value)
        let pair = StarvedPair(
            server: server,
            clientEndpoint: clientEndpoint,
            link: link,
            client: client,
            host: host,
            clientControl: IrxControlByteTransport(connection: client, control: clientLane, closeCode: .explicitRedial),
            hostControl: IrxControlByteTransport(connection: host, control: hostLane, closeCode: .hostShutdown)
        )
        try await pair.clientControl.connect()
        try await pair.hostControl.connect()
        pair.serveHost()
        return pair
    }

    /// The host as the Mac runs it: keepalive lanes answered by
    /// `respondKeepalive`, every control request answered on the control stream.
    private func serveHost() {
        let host = self.host
        let hostControl = self.hostControl
        tasks.add(Task {
            while !Task.isCancelled, let lane = await host.acceptLane() {
                if lane.descriptor.lane == .keepalive { _ = host.respondKeepalive(on: lane) }
            }
        })
        tasks.add(Task {
            while !Task.isCancelled, let request = try? await hostControl.receive() {
                try? await hostControl.send(Data("reply:".utf8) + request)
            }
        })
    }

    /// The host writes output continuously on a background surface lane, as
    /// `MobileHostIrxEventWriter` does; the client reads all of it. Returns
    /// once the path is saturated.
    func startOutput() async throws {
        let host = self.host
        let lanes = IrxSurfaceEventLanes { descriptor in try await host.openUniLane(descriptor) }
        tasks.add(Task {
            while !Task.isCancelled {
                do {
                    try await lanes.send(Self.outputFrame, surfaceID: "starved-output", generation: 1)
                } catch {
                    return
                }
            }
        })
        let client = self.client
        let reader = self.reader
        tasks.add(Task {
            guard let (_, lane) = try? await client.acceptUniLane() else { return }
            while !Task.isCancelled {
                guard let chunk = try? await lane.readRaw() else { return }
                await reader.add(chunk.count)
            }
        })
        let deadline = ContinuousClock.now + .seconds(20)
        while await reader.bytesRead < Self.saturatedBytes {
            guard ContinuousClock.now < deadline else {
                Issue.record("the output lane delivered only \(await reader.bytesRead) bytes in 20 s")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// One control request and its reply; nil when no reply came within `timeout`.
    func controlRoundTrip(timeout: Duration) async throws -> Duration? {
        let clientControl = self.clientControl
        let started = ContinuousClock.now
        try await clientControl.send(Data("request".utf8))
        let result = try await withIrxDeadlineResult(timeout) {
            try await clientControl.receive()
        }
        guard case .operation(let reply?) = result, !reply.isEmpty else { return nil }
        return ContinuousClock.now - started
    }

    func shutDown() async {
        tasks.cancelAll()
        await clientControl.close()
        await hostControl.close()
        await client.close(code: .userRequested, origin: .local)
        await host.close(code: .userRequested, origin: .local)
        link.stop()
        try? await server.close()
        try? await clientEndpoint.close()
    }
}

/// Tasks a pair started, cancelled together at shutdown.
private final class TaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func add(_ task: Task<Void, Never>) {
        lock.withLock { tasks.append(task) }
    }

    func cancelAll() {
        let all = lock.withLock { () -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return tasks
        }
        for task in all { task.cancel() }
    }
}

// SUPERMUX:begin irx-route-sample (which path a link uses and iroh's own RTT on it — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// The route a device link shows ("Direct · LAN · 6 ms", "Relay · Tokyo ·
/// 241 ms") is read from ``IrxConnection/supermuxSelectedPathSample()``.
/// Ways that read could be wrong, checked on real iroh connections:
/// 1. It reports a path other than the selected one.
/// 2. Its RTT is not the path's (0, iroh's 333 ms initial guess, or the
///    application's own round trip): a loopback path must read under 50 ms
///    and a path with 120 ms each way 200–400 ms.
/// 3. The remote address is not the one dialed (the shaped link's socket,
///    or the relay URL), so the route cannot be classified.
/// 4. A relayed path reads as direct, or the direct path iroh moves to
///    afterwards still reads as the relay (opt-in, public relays:
///    `CMUX_IROH_PUBLIC_RELAY_TEST=1`).
@Suite("route sample on a live connection", .serialized)
struct SupermuxIrxRouteSampleTests {
    @Test("a loopback path reads direct, at the dialed address, under 50 ms", .timeLimit(.minutes(1)))
    func loopbackPathReadsDirect() async throws {
        let pair = try await SampledPair.make(shape: nil)
        try await pair.roundTrips(3)
        let sample = try #require(pair.client.supermuxSelectedPathSample())
        #expect(!sample.isRelay)
        #expect(!sample.hasRelayPath)
        #expect(sample.remoteAddress == pair.dialed)
        #expect(sample.rttMs < 50, "loopback RTT \(sample.rttMs) ms")
        print("route sample on loopback: \(sample)")
        await pair.shutDown()
    }

    @Test("a path with 120 ms each way reads 200–400 ms", .timeLimit(.minutes(1)))
    func shapedPathReadsItsRoundTrip() async throws {
        let shape = SupermuxShapedUDPLink.Shape(bytesPerSecond: 10_000_000, oneWayDelay: 0.12, queueBytes: 1_000_000)
        let pair = try await SampledPair.make(shape: shape)
        try await pair.roundTrips(5)
        let sample = try #require(pair.client.supermuxSelectedPathSample())
        #expect(!sample.isRelay)
        #expect(sample.remoteAddress == pair.dialed)
        #expect((200...400).contains(sample.rttMs), "shaped RTT \(sample.rttMs) ms")
        print("route sample on the shaped link: \(sample)")
        await pair.shutDown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_IROH_PUBLIC_RELAY_TEST"] == "1"),
          .timeLimit(.minutes(1)))
    func publicRelayReadsRelayThenDirect() async throws {
        let options = EndpointOptions(
            preset: presetMinimal(), alpns: [IrxProtocol().alpnData],
            relayMode: RelayMode.defaultMode(), portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 4, initialMaxConcurrentUniStreams: 0)
        let server = try await Endpoint.bind(options: options)
        let clientEndpoint = try await Endpoint.bind(options: options)
        await server.online()
        await clientEndpoint.online()
        let relay = try #require(server.addr().relayUrl())
        let accepting = Task {
            let incoming = try #require(await server.acceptNext())
            return try await incoming.accept().connect()
        }
        let raw = try await clientEndpoint.connect(
            addr: EndpointAddr(id: server.id(), relayUrl: relay, addresses: []), alpn: IrxProtocol().alpnData)
        let accepted = try await accepting.value
        let client = IrxConnection(connection: raw, role: .dialer, journal: IrxLiveTestSupport.journal())
        let relayed = try #require(client.supermuxSelectedPathSample())
        #expect(relayed.isRelay)
        #expect(relayed.remoteAddress == relay)
        print("route sample on the relay: \(relayed)")

        await client.authorizeDirectPaths()
        try await accepted.authorizeNatTraversal()
        var direct: SupermuxIrxPathSample?
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let sample = client.supermuxSelectedPathSample(), !sample.isRelay {
                direct = sample
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let moved = try #require(direct, "iroh never selected a direct path")
        #expect(moved.remoteAddress.contains(":"))
        #expect(moved.hasRelayPath, "the relay path stays open as a fallback")
        print("route sample once direct: \(moved)")
        await client.close(code: .userRequested, origin: .local)
        try await clientEndpoint.close()
        try await server.close()
    }
}

/// An admitted client/host pair over loopback, directly or through a
/// shaped link, whose host answers keepalive probes.
private final class SampledPair: Sendable {
    let server: Endpoint
    let clientEndpoint: Endpoint
    let link: SupermuxShapedUDPLink?
    let client: IrxConnection
    let host: IrxConnection
    let dialed: String
    private let serving: Task<Void, Never>

    private init(
        server: Endpoint, clientEndpoint: Endpoint, link: SupermuxShapedUDPLink?,
        client: IrxConnection, host: IrxConnection, dialed: String
    ) {
        self.server = server
        self.clientEndpoint = clientEndpoint
        self.link = link
        self.client = client
        self.host = host
        self.dialed = dialed
        serving = Task {
            while !Task.isCancelled, let lane = await host.acceptLane() {
                if lane.descriptor.lane == .keepalive { _ = host.respondKeepalive(on: lane) }
            }
        }
    }

    private static func bind() async throws -> Endpoint {
        try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(), bindAddr: "127.0.0.1:0", secretKey: IrxLiveTestSupport.identitySeed(),
            alpns: [IrxProtocol().alpnData], relayMode: RelayMode.disabled(), portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 8, initialMaxConcurrentUniStreams: 8))
    }

    static func make(shape: SupermuxShapedUDPLink.Shape?) async throws -> SampledPair {
        let journal = IrxLiveTestSupport.journal()
        let server = try await bind()
        let clientEndpoint = try await bind()
        let serverAddress = try #require(IrxLiveTestSupport.loopbackAddr(of: server).directAddresses().first)
        let serverPort = try #require(serverAddress.split(separator: ":").last.flatMap { UInt16($0) })
        let link = try shape.map { try SupermuxShapedUDPLink(hostPort: serverPort, shape: $0) }
        let dialed = link?.clientFacingAddress ?? serverAddress
        let serverTask = Task { () -> IrxConnection? in
            guard let incoming = await server.acceptNext() else { return nil }
            let native = try await incoming.accept().connect()
            let irx = IrxConnection(connection: native, role: .acceptor, journal: journal)
            guard await IrxAdmission().performServer(
                connection: irx, judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal) != nil else { return nil }
            return irx
        }
        let native = try await clientEndpoint.connect(
            addr: EndpointAddr(id: server.id(), relayUrl: nil, addresses: [dialed]), alpn: IrxProtocol().alpnData)
        let client = IrxConnection(connection: native, role: .dialer, journal: journal)
        _ = try await IrxAdmission().performClient(connection: client, grantJWS: "good-grant", journal: journal)
        let host = try #require(try await serverTask.value)
        return SampledPair(
            server: server, clientEndpoint: clientEndpoint, link: link, client: client, host: host, dialed: dialed)
    }

    /// Keepalive probes, so QUIC has RTT samples beyond the handshake.
    func roundTrips(_ count: Int) async throws {
        for _ in 0..<count {
            let answered = await client.probeLiveness(deadline: .seconds(3))
            try #require(answered, "the host did not answer a keepalive probe")
        }
    }

    func shutDown() async {
        serving.cancel()
        await client.close(code: .userRequested, origin: .local)
        await host.close(code: .userRequested, origin: .local)
        link?.stop()
        try? await server.close()
        try? await clientEndpoint.close()
    }
}
// SUPERMUX:end irx-route-sample

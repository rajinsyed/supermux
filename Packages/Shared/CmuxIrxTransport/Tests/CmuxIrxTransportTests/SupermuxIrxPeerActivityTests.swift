// SUPERMUX:begin transport-peer-liveness (a device link is judged dead only when its connection shows no life — see SUPERMUX-TOUCHPOINTS.md)
import CMUXMobileCore
import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// After a request misses its reply deadline, the device link asks the
/// transport whether the other Mac still shows life before it redials
/// (``SupermuxByteTransportPeerActivity``). Before, it asked with a
/// `mobile.events.probe` on the same control stream, which on a congested
/// relay waited behind the very bulk that made the request late, so a link
/// carrying bytes the whole time was declared lost and redialed.
///
/// Ways that evidence could be wrong, one test each:
/// 1. A host whose control stream never answers, while another of its lanes
///    keeps delivering, reads as dead.
/// 2. An idle host (nothing arrived since the window began) that still
///    answers a transport keepalive reads as dead.
/// 3. Bytes that arrived before the window began count as life now, so a
///    dead link is kept.
/// 4. A host that answers nothing and sent nothing in the window reads as
///    alive, so a dead link is kept.
/// 5. A closed connection reads as alive.
@Suite("peer activity evidence for a device link's liveness check", .serialized)
struct SupermuxIrxPeerActivityTests {
    @Test("output on another lane proves life while the control stream never answers", .timeLimit(.minutes(1)))
    func outputOnAnotherLaneProvesLife() async throws {
        let pair = try await PeerActivityPair.make(answersKeepalive: false)
        let start = ContinuousClock.now
        try await pair.deliverOutput()
        #expect(await pair.clientControl.supermuxPeerShowsLife(since: start, probeDeadline: nil))
        await pair.shutDown()
    }

    @Test("an idle host that answers a keepalive is alive; its older bytes alone are not", .timeLimit(.minutes(1)))
    func idleHostAnsweringKeepaliveIsAlive() async throws {
        let pair = try await PeerActivityPair.make(answersKeepalive: true)
        let start = ContinuousClock.now
        #expect(
            await !pair.clientControl.supermuxPeerShowsLife(since: start, probeDeadline: nil),
            "admission bytes that arrived before the window must not count"
        )
        #expect(await pair.clientControl.supermuxPeerShowsLife(since: start, probeDeadline: .seconds(2)))
        await pair.shutDown()
    }

    @Test("a host that answers nothing and sent nothing in the window is not alive", .timeLimit(.minutes(1)))
    func silentHostIsNotAlive() async throws {
        let pair = try await PeerActivityPair.make(answersKeepalive: false)
        let start = ContinuousClock.now
        #expect(await !pair.clientControl.supermuxPeerShowsLife(since: start, probeDeadline: .milliseconds(500)))
        #expect(start.duration(to: .now) >= .milliseconds(500), "the keepalive probe must have run to its deadline")
        await pair.shutDown()
    }

    @Test("a closed connection is not alive", .timeLimit(.minutes(1)))
    func closedConnectionIsNotAlive() async throws {
        let pair = try await PeerActivityPair.make(answersKeepalive: true)
        let start = ContinuousClock.now - .seconds(60)
        await pair.client.close(code: .userRequested, origin: .local)
        #expect(await !pair.clientControl.supermuxPeerShowsLife(since: start, probeDeadline: .seconds(1)))
        await pair.shutDown()
    }
}

/// An admitted client/host pair over loopback whose host never answers the
/// control stream, may answer keepalive lanes, and can send output on an
/// events lane.
private final class PeerActivityPair: Sendable {
    let server: Endpoint
    let clientEndpoint: Endpoint
    let client: IrxConnection
    let host: IrxConnection
    let clientControl: IrxControlByteTransport
    private let serving: Task<Void, Never>

    private init(
        server: Endpoint, clientEndpoint: Endpoint, client: IrxConnection, host: IrxConnection,
        clientControl: IrxControlByteTransport, serving: Task<Void, Never>
    ) {
        self.server = server
        self.clientEndpoint = clientEndpoint
        self.client = client
        self.host = host
        self.clientControl = clientControl
        self.serving = serving
    }

    private static func bind() async throws -> Endpoint {
        try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            bindAddr: "127.0.0.1:0",
            secretKey: IrxLiveTestSupport.identitySeed(),
            alpns: [IrxProtocol().alpnData],
            relayMode: RelayMode.disabled(),
            portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: false,
            initialMaxConcurrentBiStreams: 8,
            initialMaxConcurrentUniStreams: 8
        ))
    }

    static func make(answersKeepalive: Bool) async throws -> PeerActivityPair {
        let journal = IrxLiveTestSupport.journal()
        let server = try await bind()
        let clientEndpoint = try await bind()
        let serverTask = Task { () -> IrxConnection? in
            guard let incoming = await server.acceptNext() else { return nil }
            let native = try await incoming.accept().connect()
            let irx = IrxConnection(connection: native, role: .acceptor, journal: journal)
            guard await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            ) != nil else { return nil }
            return irx
        }
        let native = try await clientEndpoint.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server),
            alpn: IrxProtocol().alpnData
        )
        let client = IrxConnection(connection: native, role: .dialer, journal: journal)
        let (_, clientLane) = try await IrxAdmission().performClient(
            connection: client, grantJWS: "good-grant", journal: journal)
        let host = try #require(try await serverTask.value)
        let clientControl = IrxControlByteTransport(connection: client, control: clientLane, closeCode: .explicitRedial)
        try await clientControl.connect()
        // The control lane the admission returned is never read or answered.
        // A silent host holds its keepalive lanes open without answering, as
        // a stalled process does (dropping one would end the probe early).
        let serving = Task {
            var unanswered: [IrxLaneStream] = []
            while !Task.isCancelled, let lane = await host.acceptLane() {
                if answersKeepalive, lane.descriptor.lane == .keepalive {
                    _ = host.respondKeepalive(on: lane)
                } else {
                    unanswered.append(lane)
                }
            }
            withExtendedLifetime(unanswered) {}
        }
        return PeerActivityPair(
            server: server, clientEndpoint: clientEndpoint, client: client, host: host,
            clientControl: clientControl, serving: serving
        )
    }

    /// The host writes one frame on an events lane; returns once the client read it.
    func deliverOutput() async throws {
        let lane = try await host.openUniLane(IrxLaneDescriptor(lane: .events))
        try await lane.write(Data(repeating: 0x61, count: 1024))
        let (_, reader) = try #require(try await client.acceptUniLane())
        let chunk = try await reader.readRaw()
        #expect(chunk?.isEmpty == false, "the client must read the host's output")
    }

    func shutDown() async {
        serving.cancel()
        await clientControl.close()
        await client.close(code: .userRequested, origin: .local)
        await host.close(code: .userRequested, origin: .local)
        try? await server.close()
        try? await clientEndpoint.close()
    }
}
// SUPERMUX:end transport-peer-liveness

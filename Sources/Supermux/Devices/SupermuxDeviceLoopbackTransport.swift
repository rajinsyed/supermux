#if DEBUG
import CMUXMobileCore
import Foundation

/// One end of the DEBUG loopback device's in-memory duplex byte transport.
///
/// ``makePair()`` wires two ends back to back: what the client end sends the
/// server end receives, and vice versa. The client end plugs into the
/// device link's `MobileCoreRPCClient`; the server end into this app's own
/// `MobileHostService.acceptTransport`. Closing either end ends the stream
/// for both, the way a dropped socket would.
final class SupermuxDeviceLoopbackTransport: CmxByteTransport {
    private let inbound: SupermuxDeviceLoopbackPipe
    private let outbound: SupermuxDeviceLoopbackPipe

    private init(inbound: SupermuxDeviceLoopbackPipe, outbound: SupermuxDeviceLoopbackPipe) {
        self.inbound = inbound
        self.outbound = outbound
    }

    static func makePair() -> (client: SupermuxDeviceLoopbackTransport, server: SupermuxDeviceLoopbackTransport) {
        let clientToServer = SupermuxDeviceLoopbackPipe()
        let serverToClient = SupermuxDeviceLoopbackPipe()
        return (
            client: SupermuxDeviceLoopbackTransport(inbound: serverToClient, outbound: clientToServer),
            server: SupermuxDeviceLoopbackTransport(inbound: clientToServer, outbound: serverToClient)
        )
    }

    /// Already connected: both ends exist from the moment the pair is made.
    func connect() async throws {}

    func receive() async throws -> Data? {
        try await inbound.read()
    }

    func send(_ data: Data) async throws {
        try await outbound.write(data)
    }

    func close() async {
        await outbound.close()
        await inbound.close()
    }
}
#endif

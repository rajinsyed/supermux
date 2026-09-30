#if DEBUG
import CMUXMobileCore
import Foundation

/// The DEBUG loopback device's dialer: every dial makes a fresh in-memory
/// transport pair, hands the server end to ``accept`` (this app's own mobile
/// host) and returns the client end to the device link's RPC client. The
/// route is ignored; there is exactly one peer, and it is this process.
struct SupermuxDeviceLoopbackTransportFactory: CmxByteTransportFactory {
    let accept: @Sendable (any CmxByteTransport) -> Void

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let pair = SupermuxDeviceLoopbackTransport.makePair()
        accept(pair.server)
        return pair.client
    }
}
#endif

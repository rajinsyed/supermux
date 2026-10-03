import CmuxIrxTransport
import Foundation
import Network

/// Which tunnel host serves an admitted connection's `tcp_connect` and
/// `listening_ports` lanes, called from `MobileHostIrxRuntime`'s
/// `device-tunnel-host` fence (and by the DEBUG loopback device, so E2E runs
/// the same decision):
///
/// - A phone gets upstream's "On iPhone" browser tunnel, unchanged.
/// - Another of the user's Macs gets port forwarding and its mirrors' browsers:
///   this Mac's loopback only (whatever the iPhone-labelled
///   `mobile.browserTunnel.allowOtherHosts` says), its own limits, and the loop
///   guard. Every open re-checks the session's live authorization and the
///   managed embedded-browser lock, as the phone's tunnel does.
enum SupermuxDeviceTunnelHosts {
    /// Mac peers: dev-server bursts, HMR sockets, forwarded ports. Kept under the
    /// connection's 64 client bi-stream credit (IrxAdmission.swift:258); a Mac
    /// client opens only its control lane besides tunnels (DeviceIrxClient has no
    /// terminal lanes), so 48 leaves headroom.
    nonisolated static var macPeerLimits: IrxTunnelHost.Limits {
        IrxTunnelHost.Limits(maximumConcurrentTunnels: 48, openBurst: 96, opensPerSecond: 48)
    }

    nonisolated static func makeHost(
        peerIsMac: Bool, isAuthorized: @escaping @Sendable () -> Bool, journal: IrxJournal
    ) -> IrxTunnelHost? {
        guard peerIsMac else { return MobileHostBrowserTunnel.makeHost(isAuthorized: isAuthorized, journal: journal) }
        return IrxTunnelHost(
            limits: macPeerLimits,
            connector: SupermuxLoopGuardConnector(),
            // Loopback only, whatever the iPhone-labelled `mobile.browserTunnel.allowOtherHosts` says.
            policy: { IrxTunnelDestinationPolicy(allowsNonLoopbackHosts: false) },
            isAuthorized: { MobileHostBrowserTunnel.isAvailable && isAuthorized() },
            journal: journal
        )
    }
}

/// Refuses ports this app itself listens on for forwards and browser proxies, so a
/// forward never tunnels into another forward (in the loopback harness, viewer and
/// owner are one app, so a same-port forward would loop forever).
struct SupermuxLoopGuardConnector: IrxTunnelConnecting {
    private let base = IrxTunnelNetworkConnector()

    func resolve(host: String) async -> [IrxTunnelIPAddress] { await base.resolve(host: host) }

    func connect(to addresses: [IrxTunnelIPAddress], port: Int, timeout: Duration)
        async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel {
        #if DEBUG
        let port = SupermuxLoopbackServedPorts.shared.source(for: port)
        #endif
        guard !SupermuxOwnListenerPorts.shared.contains(port) else { throw IrxTunnelOpenError(status: .denied) }
        return SupermuxEndOfStreamChannel(base: try await base.connect(to: addresses, port: port, timeout: timeout))
    }
}

/// Upstream's channel throws Network.framework's end-of-stream ENODATA
/// (``NWError/supermuxIsEndOfStream``), so `IrxTunnelHost.relay` aborted the
/// lane after the server's whole answer and the other Mac read a reset
/// instead of the end of the stream. This reads it as the end.
struct SupermuxEndOfStreamChannel: IrxTunnelByteChannel {
    let base: any IrxTunnelByteChannel

    func receive(maximumByteCount: Int) async throws -> Data? {
        do {
            return try await base.receive(maximumByteCount: maximumByteCount)
        } catch let error as NWError where error.supermuxIsEndOfStream {
            return nil
        }
    }

    func send(_ data: Data) async throws { try await base.send(data) }
    func finishSending() async { await base.finishSending() }
    func cancel() { base.cancel() }
}

#if DEBUG
/// E2E (`supermux.devices.tunnel.serve_port`): gives the loopback owner a port of
/// its own. In the loopback harness the owning Mac and this Mac are one machine,
/// so the owner's port P is always busy here and a forward of P can never listen
/// on P, as it does between two Macs whenever P is free on the viewing one. With
/// P served from another port Q of this machine, the owner's tunnel host dials Q
/// when asked for P, so P stays free here. Empty unless a suite sets it.
final class SupermuxLoopbackServedPorts: @unchecked Sendable {
    static let shared = SupermuxLoopbackServedPorts()

    private let lock = NSLock()
    private var sources: [Int: Int] = [:]

    /// Serves `port` from `source`, or as itself again when `source` is nil.
    func serve(_ port: Int, from source: Int?) {
        lock.lock()
        defer { lock.unlock() }
        sources[port] = source
    }

    /// The port of this machine that serves the owner's `port`.
    func source(for port: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sources[port] ?? port
    }
}
#endif

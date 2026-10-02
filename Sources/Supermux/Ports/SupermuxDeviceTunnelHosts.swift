import CmuxIrxTransport
import Foundation

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
        guard !SupermuxOwnListenerPorts.shared.contains(port) else { throw IrxTunnelOpenError(status: .denied) }
        return try await base.connect(to: addresses, port: port, timeout: timeout)
    }
}

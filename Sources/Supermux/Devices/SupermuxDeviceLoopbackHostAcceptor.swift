#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

/// The host half of the DEBUG loopback device: admits the server end of each
/// loopback transport into this app's own mobile host exactly the way
/// `MobileHostIrxRuntime` admits an Iroh Mac peer — `.irohAdmission` of a Mac
/// grant peer, the peer-only `device.workspace.*` layout methods in front of
/// the ordinary dispatcher, and `mobile.host.status` answering with the
/// loopback's device id so the link's identity check matches its row.
///
/// Deliberate difference from the real runtime: there is no Iroh listener,
/// no directory admission and no "Make this Mac discoverable" gate. The
/// harness is DEBUG-only and explicitly opted into, and managed policy
/// (`MobileRemoteControlPolicy.isDisabled`) still refuses every connection.
/// A connection lives until either end closes; the harness itself lives as
/// long as the app.
@MainActor
final class SupermuxDeviceLoopbackHostAcceptor {
    /// The method the next connection answers busy once (see
    /// ``BusyRequest``); armed by the DEBUG `supermux.devices.link
    /// {action: "restore", busy: "<method>"}`.
    static var busyMethodForNextConnection: String?
    /// The method whose next request the loopback host holds, and for how
    /// many seconds (see ``holdIfStalled(_:)``); armed by the DEBUG
    /// `supermux.devices.link {action: "stall", method, seconds}`.
    static var stalledRequest: (method: String, seconds: Double)?
    /// How long the main thread is blocked once the next liveness probe after
    /// a missed deadline is on its way (see ``blockMainDuringLivenessProbeIfArmed()``);
    /// armed by the DEBUG `supermux.devices.link {action: "stall", main_seconds}`.
    static var mainStallDuringNextLivenessProbe: Double?
    /// How many more requests for each method the loopback host fails (see
    /// ``FailingRequests``); armed by the DEBUG `supermux.devices.tunnel.fail_requests`.
    static var failingRequests: [String: Int] = [:]
    /// How many requests for each method it failed since that was last armed.
    static var failedRequests: [String: Int] = [:]
    /// Connections admitted since launch: a link that redials adds one, which
    /// E2E reads through `supermux.devices.link {action: "status"}`.
    private(set) static var admittedConnections = 0
    /// The loopback tunnel host's own journal (`host-tunnel` events), read by
    /// the DEBUG `supermux.devices.tunnel.journal` driver.
    nonisolated static let tunnelJournal = IrxJournal(subsystem: "dev.supermux", category: "loopback-tunnel")
    /// Stands in for a revoked peer: every tunnel open is refused while set
    /// (DEBUG `supermux.devices.tunnel.revoke`). Read from the host's
    /// `@Sendable` authorization check.
    nonisolated(unsafe) static var tunnelAuthorizationRevoked = false

    private let peer: CmxIrohAdmittedPeer
    private let layouts: DeviceWorkspaceLayoutHost
    /// The newest connection's tunnel host, as `MobileHostIrxRuntime` builds
    /// one per admitted connection. Kept after its connection ends (stopped)
    /// so E2E can watch its tunnels drain; the next admission replaces it.
    private var tunnelHost: IrxTunnelHost?
    /// Whether ``tunnelHost``'s connection is still open.
    private var tunnelConnectionLive = false

    init(identity: SupermuxDeviceLoopbackIdentity) throws {
        peer = try identity.admittedPeer()
        layouts = Self.makeLayoutHost()
    }

    /// The same closures as `MobileHostIrxRuntime.deviceWorkspaceLayouts`,
    /// which is private to the Iroh runtime and only built for admitted Mac peers.
    private static func makeLayoutHost() -> DeviceWorkspaceLayoutHost {
        DeviceWorkspaceLayoutHost(
            capture: { Workspace.liveWorkspace(id: $0)?.deviceWorkspaceLayoutSnapshot() },
            apply: { id, layout in
                guard let workspace = Workspace.liveWorkspace(id: id) else { throw DeviceLinkError.notConnected }
                try workspace.applyDeviceWorkspaceLayout(layout)
            },
            createTerminal: { id, source, direction in
                Workspace.liveWorkspace(id: id)?.createDeviceWorkspaceTerminal(near: source, direction: direction)
            },
            publish: { snapshot in
                guard let data = try? JSONEncoder().encode(snapshot),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                MobileHostService.emitEvent(topic: DeviceWorkspaceLayoutHost.eventTopic, payload: payload)
            }
        )
    }

    /// Called from the transport factory, off the main actor, once per dial.
    nonisolated func accept(_ transport: any CmxByteTransport) {
        Task { @MainActor in self.admit(transport) }
    }

    private func admit(_ transport: any CmxByteTransport) {
        let peer = self.peer
        let layouts = self.layouts
        let busy = BusyRequest(method: Self.busyMethodForNextConnection)
        let failing = FailingRequests()
        Self.busyMethodForNextConnection = nil
        Self.admittedConnections += 1
        // The same tunnel host a real Mac peer's connection gets; the
        // authorization stands in for `stillAuthorized` (the harness never
        // turns on "Make this Mac discoverable").
        let host = SupermuxDeviceTunnelHosts.makeHost(
            peerIsMac: true,
            isAuthorized: {
                MobileRemoteControlPolicy.isEnabled && !SupermuxDeviceLoopbackHostAcceptor.tunnelAuthorizationRevoked
            },
            journal: Self.tunnelJournal
        )
        tunnelHost = host
        tunnelConnectionLive = true
        cmuxDebugLog("supermux.loopback host admitted connection")
        Task {
            let exit = await MobileHostService.acceptTransport(
                transport,
                authorization: .irohAdmission(peer),
                hostDeviceID: SupermuxDeviceLoopbackIdentity.deviceID,
                firstFrameTimeoutNanoseconds: 0,
                peerRequestHandler: { request in
                    if let refused = await busy.answer(request) { return refused }
                    if let failed = await failing.answer(request) { return failed }
                    await Self.holdIfStalled(request)
                    return await layouts.handle(request)
                },
                isCurrent: { true }
            )
            await transport.close()
            await host?.stop()
            if self.tunnelHost === host { self.tunnelConnectionLive = false }
            cmuxDebugLog("supermux.loopback host connection ended: \(String(describing: exit.lifecycle))")
        }
    }

    /// Opens one tunnel lane on the newest connection, as `IrxTunnelClient.connect`
    /// does on a QUIC connection: the tunnel host answers, and a refusal
    /// throws `IrxTunnelOpenError` with its status. Without a tunnel host the
    /// lane is reset, as `runLaneLoop` does, which the viewer sees as `.failed`.
    func openTunnel(host: String, port: Int) async throws -> SupermuxDeviceLoopbackTunnelLane.ClientHalf {
        let (hostHalf, client) = SupermuxDeviceLoopbackTunnelLane.pair(host: host, port: port)
        guard let tunnelHost else {
            await client.abort()
            throw IrxTunnelOpenError(status: .failed)
        }
        await tunnelHost.accept(hostHalf)
        let reply = try await client.readReply(timeout: .seconds(15))
        guard reply.status == .connected else {
            await client.abort()
            throw IrxTunnelOpenError(status: reply.status)
        }
        return client
    }

    /// The newest connection's tunnel host, for the DEBUG `tunnel.host_state` driver.
    func tunnelHostState() async -> (hasHost: Bool, connectionLive: Bool, activeTunnels: Int) {
        guard let tunnelHost else { return (false, false, 0) }
        return (true, tunnelConnectionLive, await tunnelHost.activeTunnelCount)
    }

    /// Holds the first request for the stalled method (any connection) for
    /// the armed seconds, then lets it run as usual: one slow host call, as a
    /// git command or file read in a folder behind an unanswered macOS privacy
    /// prompt is. The connection keeps answering everything else meanwhile.
    private static func holdIfStalled(_ request: MobileHostRPCRequest) async {
        guard let stall = stalledRequest, stall.method == request.method else { return }
        stalledRequest = nil
        cmuxDebugLog("supermux.loopback host holds \(stall.method) for \(stall.seconds) s")
        try? await Task.sleep(for: .milliseconds(Int(stall.seconds * 1000)))
    }

    /// Called by the viewer's link as it sends the liveness probe that follows
    /// a missed deadline: once armed, blocks the main thread for the armed
    /// seconds from the moment the link awaits the probe's answer, as a host
    /// whose main thread is stuck (a synchronous file access behind an
    /// unanswered macOS privacy prompt) is. The loopback host is this same
    /// app, so this is the host's main thread while the probe is answered.
    static func blockMainDuringLivenessProbeIfArmed() {
        guard let seconds = mainStallDuringNextLivenessProbe else { return }
        mainStallDuringNextLivenessProbe = nil
        cmuxDebugLog("supermux.loopback host blocks its main thread for \(seconds) s during the liveness probe")
        // Runs right after the current main-actor job, which ends where the
        // link starts awaiting the probe's answer.
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: seconds) }
    }
}

/// One connection's armed fault: the first request for `method` after the
/// post-connect `mobile.sync.fetch` (so a `mobile.host.status` is the viewer's
/// capability request, not the dial's identity check) is answered
/// `server_busy`, word for word what the host answers while its
/// per-connection request quota is full, as it is when every mirrored
/// terminal re-attaches at once after a reconnect.
@MainActor
private final class BusyRequest {
    private var method: String?
    private var fetched = false

    init(method: String?) {
        self.method = method
    }

    func answer(_ request: MobileHostRPCRequest) -> MobileHostRPCResult? {
        if request.method == "mobile.sync.fetch" { fetched = true }
        guard fetched, let method, request.method == method else { return nil }
        self.method = nil
        cmuxDebugLog("supermux.loopback host answered \(method) busy")
        return .failure(MobileHostRPCError(code: "server_busy", message: "Too many requests are pending"))
    }
}

/// One connection's share of the armed failures
/// (``SupermuxDeviceLoopbackHostAcceptor/failingRequests``): once the
/// connection's `mobile.sync.fetch` ran (so the dial's own `mobile.host.status`
/// identity check passes), each armed request is answered `timed_out`, the
/// failure the viewer's link reports for a request whose reply missed its
/// deadline while the other Mac still answers (#723), so the viewer's
/// capability or port listing fetch fails as it does on a stalled Mac.
@MainActor
private final class FailingRequests {
    private var fetched = false

    func answer(_ request: MobileHostRPCRequest) -> MobileHostRPCResult? {
        if request.method == "mobile.sync.fetch" { fetched = true }
        guard fetched, let remaining = SupermuxDeviceLoopbackHostAcceptor.failingRequests[request.method],
              remaining > 0 else { return nil }
        SupermuxDeviceLoopbackHostAcceptor.failingRequests[request.method] = remaining - 1
        SupermuxDeviceLoopbackHostAcceptor.failedRequests[request.method, default: 0] += 1
        cmuxDebugLog("supermux.loopback host failed \(request.method) (\(remaining - 1) more armed)")
        return .failure(MobileHostRPCError(
            code: SupermuxDeviceLinkEvents.missedDeadlineCode, message: "The host did not answer in time"
        ))
    }
}
#endif

#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
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

    private let peer: CmxIrohAdmittedPeer
    private let layouts: DeviceWorkspaceLayoutHost

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
        Self.busyMethodForNextConnection = nil
        cmuxDebugLog("supermux.loopback host admitted connection")
        Task {
            let exit = await MobileHostService.acceptTransport(
                transport,
                authorization: .irohAdmission(peer),
                hostDeviceID: SupermuxDeviceLoopbackIdentity.deviceID,
                firstFrameTimeoutNanoseconds: 0,
                peerRequestHandler: { request in
                    if let refused = await busy.answer(request) { return refused }
                    return await layouts.handle(request)
                },
                isCurrent: { true }
            )
            await transport.close()
            cmuxDebugLog("supermux.loopback host connection ended: \(String(describing: exit.lifecycle))")
        }
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
#endif

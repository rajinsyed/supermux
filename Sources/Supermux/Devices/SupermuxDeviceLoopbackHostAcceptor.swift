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
@MainActor
final class SupermuxDeviceLoopbackHostAcceptor {
    private let peer: CmxIrohAdmittedPeer
    private let layouts: DeviceWorkspaceLayoutHost
    private var isAccepting = true
    private var connections: [UUID: Task<Void, Never>] = [:]

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

    var activeConnectionCount: Int { connections.count }

    /// Called from the transport factory, off the main actor, once per dial.
    nonisolated func accept(_ transport: any CmxByteTransport) {
        Task { @MainActor in self.admit(transport) }
    }

    /// Stops admitting and ends every live loopback connection; the link sees
    /// its transport close and reconnects only if the harness starts again.
    func stop() {
        isAccepting = false
        for task in connections.values { task.cancel() }
        connections.removeAll()
    }

    private func admit(_ transport: any CmxByteTransport) {
        guard isAccepting else {
            Task { await transport.close() }
            return
        }
        let id = UUID()
        let peer = self.peer
        let layouts = self.layouts
        connections[id] = Task { [weak self] in
            let exit = await MobileHostService.acceptTransport(
                transport,
                authorization: .irohAdmission(peer),
                hostDeviceID: SupermuxDeviceLoopbackIdentity.deviceID,
                firstFrameTimeoutNanoseconds: 0,
                peerRequestHandler: { request in await layouts.handle(request) },
                isCurrent: { [weak self] in await self?.isAccepting == true }
            )
            await transport.close()
            cmuxDebugLog("supermux.loopback host connection ended: \(String(describing: exit.lifecycle))")
            self?.connections[id] = nil
        }
        cmuxDebugLog("supermux.loopback host admitted connection \(id.uuidString.prefix(8))")
    }
}
#endif

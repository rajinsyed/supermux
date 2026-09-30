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
        cmuxDebugLog("supermux.loopback host admitted connection")
        Task {
            let exit = await MobileHostService.acceptTransport(
                transport,
                authorization: .irohAdmission(peer),
                hostDeviceID: SupermuxDeviceLoopbackIdentity.deviceID,
                firstFrameTimeoutNanoseconds: 0,
                peerRequestHandler: { request in await layouts.handle(request) },
                isCurrent: { true }
            )
            await transport.close()
            cmuxDebugLog("supermux.loopback host connection ended: \(String(describing: exit.lifecycle))")
        }
    }
}
#endif

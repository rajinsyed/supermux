#if DEBUG
import CMUXMobileCore
import CmuxCloud
import CmuxIrohTransport
import CmuxSurfaceCatalogModel
import Foundation

/// The fixed, synthetic identity of the DEBUG loopback device: one other
/// "Mac" whose host is this very process.
///
/// The device id is a constant UUID that is never a real registry id, so the
/// loopback is a distinct machine (`device:<uuid>@<tag>`) next to this Mac and
/// any real devices. The instance tag is this app's own tag: the host reports
/// `mac_instance_tag` from `MobileHostIdentity.instanceTag()`, and a dev
/// viewer only shows device instances of its own tag, so reusing it makes
/// both the link's identity check and the catalog's visibility rule pass
/// without any upstream exception. The host-side acceptor answers
/// `mobile.host.status` with ``deviceID`` (see ``SupermuxDeviceLoopbackHostAcceptor``).
struct SupermuxDeviceLoopbackIdentity: Sendable {
    /// Canonical lowercase UUID; `5e1f` reads "self".
    static let deviceID = "5e1f10b0-0000-4000-8000-000000000001"
    /// 32 synthetic bytes in Iroh's canonical 64-hex form. The in-memory dialer
    /// ignores it; it exists so the route has the Iroh shape real Mac peers use,
    /// which makes the link authenticate by transport admission (no Stack token).
    static let endpointID = String(repeating: "5e1f10b0", count: 8)
    /// The host keys reconnect overlap and per-peer quotas by binding id.
    static let bindingID = "supermux-debug-loopback"

    let instance: SurfaceDeviceInstanceID

    init(tag: String = MobileHostIdentity.instanceTag()) {
        instance = SurfaceDeviceInstanceID(deviceID: Self.deviceID, tag: tag)
    }

    var machine: SurfaceMachineID { .device(instance) }

    func endpoint() throws -> CmxIrohPeerIdentity {
        try CmxIrohPeerIdentity(endpointID: Self.endpointID)
    }

    /// An Iroh-kind route, so ``DeviceRouteSelector`` picks it and the RPC
    /// client uses transport admission exactly like a real Mac-to-Mac link.
    func route() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: CmxAttachTransportKind.iroh.rawValue,
            kind: .iroh,
            endpoint: .peer(identity: endpoint(), pathHints: []),
            priority: 0
        )
    }

    /// The directory row the provider and link are built from: online,
    /// same account, dialable over the one route.
    func directoryRecord(deviceName: String) throws -> DeviceDirectoryRecord {
        var record = DeviceDirectoryRecord(
            instance: instance,
            deviceName: deviceName,
            platform: "mac",
            bundleID: Bundle.main.bundleIdentifier,
            presenceState: .online,
            isPaired: false,
            lastSeenAt: nil,
            routes: [try route()],
            ownerUserID: nil,
            accountTrust: .sameAccount
        )
        record.directoryEndpoint = try endpoint()
        record.controlPlaneSupport = .supported
        return record
    }

    /// The Mac-peer admission the host sees for every loopback connection.
    func admittedPeer() throws -> CmxIrohAdmittedPeer {
        CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
            bindingID: Self.bindingID,
            deviceID: Self.deviceID,
            tag: instance.tag,
            platform: .mac,
            endpointID: try endpoint(),
            identityGeneration: 1
        ))
    }
}
#endif

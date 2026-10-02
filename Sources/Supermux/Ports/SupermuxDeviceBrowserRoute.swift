import CmuxCore
import CmuxSurfaceCatalogModel
import CryptoKit
import Foundation
import SupermuxKit

/// Where a browser in a device mirror sends its requests.
///
/// BrowserPanel's `device-mirror-browser-route` fence (init and
/// `reattachToWorkspace`, every creation path: new tab, split, terminal link,
/// restore, the Dock, a tab moved in or out) passes its workspace parameters
/// through ``route(workspaceID:isRemoteWorkspace:proxyEndpoint:dataStoreID:)``.
/// A bound mirror's browsers then use upstream's remote-workspace mode:
/// navigation waits for, then goes through, the owning Mac's proxy
/// (``SupermuxDeviceBrowserProxies``), so `localhost` there is that Mac's; and
/// they keep one persistent website data store per remote app instance
/// (``websiteDataStoreID(for:)``), so a login to that Mac's dev app survives a
/// mirror's re-creation and never mixes with this Mac's own `localhost` cookies.
/// Public sites load from this Mac, but not signed in with the profile's cookies
/// (as upstream SSH workspaces).
///
/// `Workspace.isRemoteWorkspace` stays false for mirrors, so no SSH status UI.
@MainActor
enum SupermuxDeviceBrowserRoute {
    struct Route {
        let isRemoteWorkspace: Bool
        let proxyEndpoint: BrowserProxyEndpoint?
        let dataStoreID: UUID?
    }

    /// The parameters a browser of `workspaceID` is created (or reattached) with.
    /// Reads only the persisted bindings, so it is safe during session restore.
    static func route(
        workspaceID: UUID, isRemoteWorkspace: Bool,
        proxyEndpoint: BrowserProxyEndpoint?, dataStoreID: UUID?
    ) -> Route {
        guard !isRemoteWorkspace, let machine = boundMachine(workspaceID: workspaceID),
              let store = websiteDataStoreID(for: machine) else {
            return Route(isRemoteWorkspace: isRemoteWorkspace, proxyEndpoint: proxyEndpoint, dataStoreID: dataStoreID)
        }
        return Route(
            isRemoteWorkspace: true,
            proxyEndpoint: proxyEndpoint ?? SupermuxDeviceBrowserProxies.shared.endpoint(for: machine),
            dataStoreID: store
        )
    }

    /// The website data store of an app instance's mirror browsers: a
    /// name-based (RFC 4122 v5) UUID of its machine id (`device:<uuid>@<tag>`),
    /// the key its proxy has. One per app instance, because a store's proxy
    /// configuration serves every browser on it (two instances of one Mac
    /// sharing a store sent one's tabs through the other's proxy); the same on
    /// every launch, so its logins last. Nil for a machine that is not a device.
    static func websiteDataStoreID(for machine: SurfaceMachineID) -> UUID? {
        guard let instance = machine.deviceInstance else { return nil }
        var bytes = withUnsafeBytes(of: dataStoreNamespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(instance.wireValue.utf8))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
        digest[6] = (digest[6] & 0x0F) | 0x50  // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// Fixed for good: a new namespace would give every store a new identity
    /// (and lose its logins). `tests/supermux/loopback_mirror_browser_e2e.py` pins it.
    private static let dataStoreNamespace = UUID(uuidString: "503c7a18-bbc6-4c4b-beca-22549addb0eb")!

    private static func boundMachine(workspaceID: UUID) -> SurfaceMachineID? {
        // The binding store, never `SupermuxComposition.devices` (not built during restore).
        let bindings = SupermuxComposition.deviceBindings
        let ref = Workspace.liveWorkspace(id: workspaceID).flatMap { bindings.ref(forStableID: $0.stableId) }
            ?? bindings.ref(forWorkspaceID: workspaceID)
        return ref?.machine
    }
}

/// One ``SupermuxDeviceBrowserProxy`` per remote Mac, started the first time a
/// mirror browser of that Mac needs it.
@MainActor
final class SupermuxDeviceBrowserProxies {
    static let shared = SupermuxDeviceBrowserProxies()

    private var proxies: [SurfaceMachineID: SupermuxDeviceBrowserProxy] = [:]

    /// The proxy endpoint for `machine`'s mirror browsers, or nil while it is
    /// starting: those browsers' navigations wait until it is ready, when every
    /// bound mirror of that Mac gets it.
    func endpoint(for machine: SurfaceMachineID) -> BrowserProxyEndpoint? {
        let proxy = proxies[machine] ?? makeProxy(for: machine)
        proxy.start()
        return proxy.endpoint
    }

    /// The proxy for `machine`, if one was started (the DEBUG E2E driver reads its counters).
    func proxy(for machine: SurfaceMachineID) -> SupermuxDeviceBrowserProxy? {
        proxies[machine]
    }

    private func makeProxy(for machine: SurfaceMachineID) -> SupermuxDeviceBrowserProxy {
        let proxy = SupermuxDeviceBrowserProxy(machine: machine) { endpoint in
            Self.deliver(endpoint, to: machine)
        }
        proxies[machine] = proxy
        return proxy
    }

    /// Hands a ready endpoint to every bound mirror of `machine`: upstream's
    /// `applyRemoteProxyEndpointUpdate` reaches its browsers and its Dock, and
    /// resumes the navigations waiting for it.
    private static func deliver(_ endpoint: BrowserProxyEndpoint, to machine: SurfaceMachineID) {
        let bindings = SupermuxComposition.deviceBindings
        for workspace in SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces()
        where bindings.ref(forStableID: workspace.stableId)?.machine == machine {
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }
}

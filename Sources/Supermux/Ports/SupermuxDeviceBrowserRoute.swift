import CmuxCore
import CmuxSurfaceCatalogModel
import CryptoKit
import Foundation
import SupermuxKit
import WebKit

/// Where a browser in a device mirror sends its requests.
///
/// BrowserPanel's `device-mirror-browser-route` fence (init and
/// `reattachToWorkspace`, every creation path: new tab, split, terminal link,
/// restore, the Dock, a tab moved in or out) passes its workspace parameters
/// through ``route(workspaceID:isRemoteWorkspace:proxyEndpoint:dataStoreID:)``.
/// A mirror's browsers (bound, or unbound: the workspaces the ports menu offers
/// "Open in cmux Browser" in) then use upstream's remote-workspace mode:
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
    static func route(
        workspaceID: UUID, isRemoteWorkspace: Bool,
        proxyEndpoint: BrowserProxyEndpoint?, dataStoreID: UUID?
    ) -> Route {
        guard !isRemoteWorkspace, let machine = mirroredMachine(workspaceID: workspaceID),
              let store = websiteDataStoreID(for: machine) else {
            return Route(isRemoteWorkspace: isRemoteWorkspace, proxyEndpoint: proxyEndpoint, dataStoreID: dataStoreID)
        }
        // The live proxy's endpoint, never the one passed in: a workspace's stored
        // copy may name a listener that failed since.
        return Route(
            isRemoteWorkspace: true,
            proxyEndpoint: SupermuxDeviceBrowserProxies.shared.endpoint(for: machine),
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

    /// The Mac whose workspace `workspaceID` mirrors: its persisted binding
    /// (also a workspace a restore has not added to a window yet), else what
    /// its panes project, the device index's rule
    /// (``SupermuxDeviceWorkspaceIndex/ref(forLocalWorkspaceID:)``, live and
    /// restored projections) that the ports menu and chips use too.
    private static func mirroredMachine(workspaceID: UUID) -> SurfaceMachineID? {
        let bindings = SupermuxComposition.deviceBindings
        let bound = Workspace.liveWorkspace(id: workspaceID).flatMap { bindings.ref(forStableID: $0.stableId) }
            ?? bindings.ref(forWorkspaceID: workspaceID)
        return (bound ?? SupermuxComposition.deviceWorkspaceIndex.ref(forLocalWorkspaceID: workspaceID))?.machine
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
    /// browser on that app instance's data store gets it.
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

    /// Hands `machine`'s endpoint (nil while its listener restarts) to every
    /// browser on that app instance's data store, in each window's workspaces
    /// and their Docks: upstream's `setRemoteProxyEndpoint` applies it and
    /// resumes the navigations waiting for it. Only those browsers, never all of
    /// a workspace's (`Workspace.applyRemoteProxyEndpointUpdate`): an endpoint
    /// configures a browser's whole data store, so a local browser (its
    /// profile's store) must never get one.
    private static func deliver(_ endpoint: BrowserProxyEndpoint?, to machine: SurfaceMachineID) {
        guard let store = SupermuxDeviceBrowserRoute.websiteDataStoreID(for: machine) else { return }
        for workspace in SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces() {
            var panels = Array(workspace.panels.values)
            workspace._dockSplit?.forEachPanel { _, panel in panels.append(panel) }
            for case let browser as BrowserPanel in panels where browser.websiteDataStore.identifier == store {
                browser.setRemoteProxyEndpoint(endpoint)
            }
        }
    }
}

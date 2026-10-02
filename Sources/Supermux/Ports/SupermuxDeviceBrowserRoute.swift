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
/// A mirror's browsers (a bound mirror's, and an unbound one's by the rule the
/// ports menu and chips use) then use upstream's remote-workspace mode:
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

    /// Whether a mirror browser loads `url` as written instead of upstream's
    /// `localhost` alias (`http://cmux-loopback.localtest.me:P`, which the proxy
    /// sends to the owning Mac): an `http` URL on `localhost`, `127.0.0.1` or
    /// `[::1]` whose port P this Mac forwards from the browser's Mac on P itself,
    /// as port forwarding does for a server in a mirrored terminal whenever P is
    /// free here. This Mac's `localhost:P` then already is that Mac's, so the page
    /// keeps its own origin: a secure context, and the hostname a dev app's
    /// Cloudflare Turnstile sitekey, cookies and OAuth redirects name. The alias is
    /// neither, so a Turnstile login there failed (110200, Domain not authorized).
    /// WebKit never asks a proxy for a loopback host, so the load goes straight to
    /// the forward. Nil `dataStoreID` (or a store of no mirror) keeps upstream's.
    static func loadsAsWritten(_ url: URL, dataStoreID: UUID?) -> Bool {
        guard let dataStoreID, url.scheme?.lowercased() == "http",
              let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? ""),
              ["localhost", "127.0.0.1", "::1"].contains(host) else { return false }
        let port = url.port ?? 80
        return SupermuxComposition.portForwards.forwards.values.contains { forward in
            forward.key.remotePort == port && forward.localPort == port
                && websiteDataStoreID(for: forward.key.machine) == dataStoreID
        }
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
    /// (also a workspace a restore has not added to a window yet), else, for an
    /// unbound mirror, the rule of ``SupermuxDeviceWorkspaceIndex/mirrors()``
    /// that the ports menu and chips use too: every pane projects a terminal of
    /// that one remote workspace. A local workspace that only borrows a remote
    /// terminal keeps this Mac's browsers.
    private static func mirroredMachine(workspaceID: UUID) -> SurfaceMachineID? {
        let bindings = SupermuxComposition.deviceBindings
        let live = Workspace.liveWorkspace(id: workspaceID)
        let bound = live.flatMap { bindings.ref(forStableID: $0.stableId) } ?? bindings.ref(forWorkspaceID: workspaceID)
        if let bound { return bound.machine }
        let index = SupermuxComposition.deviceWorkspaceIndex
        guard let workspace = live, index.isDeviceMirror(workspace) else { return nil }
        return index.ref(forLocal: workspace)?.machine
    }
}

/// One ``SupermuxDeviceBrowserProxy`` per remote Mac, started the first time a
/// mirror browser of that Mac needs it.
@MainActor
final class SupermuxDeviceBrowserProxies {
    static let shared = SupermuxDeviceBrowserProxies()

    private var proxies: [SurfaceMachineID: SupermuxDeviceBrowserProxy] = [:]

    /// The proxy endpoint for `machine`'s mirror browsers, or nil while its
    /// first listener starts: those browsers' navigations wait until it is
    /// ready, when every browser on that app instance's data store gets it.
    /// While a failed listener is replaced it is the dead endpoint (never nil),
    /// so a new browser cannot clear the proxy of the store the open ones share.
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

    /// Hands `machine`'s new endpoint to every browser on that app instance's
    /// data store, in each window's workspaces and their Docks: upstream's
    /// `setRemoteProxyEndpoint` applies it and resumes the navigations waiting
    /// for it. Only those browsers, never all of a workspace's
    /// (`Workspace.applyRemoteProxyEndpointUpdate`): an endpoint configures a
    /// browser's whole data store, so a local browser (its profile's store)
    /// must never get one.
    private static func deliver(_ endpoint: BrowserProxyEndpoint, to machine: SurfaceMachineID) {
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

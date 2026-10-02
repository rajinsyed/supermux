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
    /// A browser that bypasses the workspace proxy (the http diff viewer, a
    /// `local`-context split) keeps upstream's: this Mac's profile store. On the
    /// mirror's store with no endpoint its loopback navigations were rerouted
    /// forever (``reroutedURL(_:dataStoreID:)``), and its proxy configuration
    /// (this Mac's system proxies) replaced the one every mirror tab shares.
    static func route(
        workspaceID: UUID, isRemoteWorkspace: Bool,
        proxyEndpoint: BrowserProxyEndpoint?, dataStoreID: UUID?, bypassesProxy: Bool
    ) -> Route {
        guard !bypassesProxy, !isRemoteWorkspace, let machine = mirroredMachine(workspaceID: workspaceID),
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

    // MARK: - As written

    /// Whether a mirror browser loads `url` as written instead of upstream's
    /// `localhost` alias (`http://cmux-loopback.localtest.me:P`, which the proxy
    /// sends to the owning Mac): an `http` URL on `localhost`, `127.0.0.1` or
    /// `[::1]` whose port P is one of ``asWrittenPorts(of:)``. This Mac's
    /// `localhost:P` then already is that Mac's, so the page keeps its own
    /// origin: a secure context, and the hostname a dev app's Cloudflare
    /// Turnstile sitekey, cookies and OAuth redirects name. The alias is neither,
    /// so a Turnstile login there failed (110200, Domain not authorized). WebKit
    /// never asks a proxy for a loopback host, so the load goes straight to the
    /// forward. Nil `dataStoreID` (or a store of no mirror) keeps upstream's.
    static func loadsAsWritten(_ url: URL, dataStoreID: UUID?) -> Bool {
        guard let machine = dataStoreID.flatMap(machine(forDataStore:)) else { return false }
        return loadsAsWritten(url, machine: machine)
    }

    /// The owning Mac's ports this Mac's `localhost` reaches as they are: each
    /// forwarded here on the same port, by an active forward, while that Mac's
    /// latest port listing still has it (so a port nothing serves there keeps
    /// the alias, whose proxy explains why it does not answer).
    static func asWrittenPorts(of machine: SurfaceMachineID) -> Set<Int> {
        let forwards = SupermuxComposition.portForwards
        let listed = Set(forwards.hostPorts[machine]?.ports.map(\.port) ?? [])
        return Set(forwards.forwards.values.compactMap { forward in
            guard forward.key.machine == machine, forward.localPort == forward.key.remotePort,
                  listed.contains(forward.key.remotePort) else { return nil }
            return forward.key.remotePort
        })
    }

    /// The URL a mirror browser's main frame must be sent to instead of `url`
    /// (the panel's own navigation then routes it), or nil when `url` already
    /// is where the route sends it: a loopback `http` URL that is not loaded as
    /// written would reach this Mac, so it goes back to the panel, which sends
    /// it through the alias; an alias URL whose port is now loaded as written
    /// becomes `localhost` again. Checked on every main-frame navigation
    /// (`device-mirror-browser-reroute`: reloads, links, redirects, back and
    /// forward) and on every change of the forwards (``forwardsChanged()``).
    static func reroutedURL(_ url: URL, dataStoreID: UUID?) -> URL? {
        guard url.scheme?.lowercased() == "http",
              let machine = dataStoreID.flatMap(machine(forDataStore:)),
              let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? "") else { return nil }
        if RemoteLoopbackProxyAlias.isLoopbackHost(host) {
            return loadsAsWritten(url, machine: machine) ? nil : url
        }
        guard host == RemoteLoopbackProxyAlias.aliasHost,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = RemoteLoopbackProxyAlias.canonicalLoopbackHost
        guard let local = components.url, loadsAsWritten(local, machine: machine) else { return nil }
        return local
    }

    /// The as-written ports last handed to each Mac's mirror browsers.
    private static var deliveredPorts: [SurfaceMachineID: Set<Int>] = [:]

    /// After a change of the forwards or the Macs' listings: each Mac whose
    /// as-written ports changed gets them in its mirror browsers' bridge
    /// (``SupermuxMirrorLoopbackBridge``), and every open page of it on the wrong
    /// side moves (``reroutedURL(_:dataStoreID:)``): a tab on `localhost:P`
    /// whose forward stopped, moved or lost its listing goes through the alias,
    /// one on the alias goes to `localhost:P` once its forward is active (a tab
    /// opened, restored or linked before the forward came up).
    static func forwardsChanged() {
        for machine in SupermuxDeviceBrowserProxies.shared.machines {
            let ports = asWrittenPorts(of: machine)
            guard deliveredPorts[machine] != ports else { continue }
            deliveredPorts[machine] = ports
            for browser in SupermuxDeviceBrowserProxies.browsers(of: machine) {
                SupermuxMirrorLoopbackBridge.update(browser.webView, ports: ports)
                let store = browser.webView.configuration.websiteDataStore.identifier
                if let url = browser.webView.url, let target = reroutedURL(url, dataStoreID: store) {
                    browser.navigateWithoutInsecureHTTPPrompt(to: target, recordTypedNavigation: false)
                }
            }
        }
    }

    /// The mirror Mac whose app instance owns this data store, if any.
    static func machine(forDataStore id: UUID) -> SurfaceMachineID? {
        SupermuxDeviceBrowserProxies.shared.machines.first { websiteDataStoreID(for: $0) == id }
    }

    private static func loadsAsWritten(_ url: URL, machine: SurfaceMachineID) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? ""),
              ["localhost", "127.0.0.1", "::1"].contains(host) else { return false }
        return asWrittenPorts(of: machine).contains(url.port ?? 80)
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

    /// The Macs whose mirror browsers have a proxy (every one that opened a mirror browser).
    var machines: [SurfaceMachineID] { Array(proxies.keys) }

    /// Every browser on `machine`'s app instance data store, in each window's
    /// workspaces and their Docks.
    static func browsers(of machine: SurfaceMachineID) -> [BrowserPanel] {
        guard let store = SupermuxDeviceBrowserRoute.websiteDataStoreID(for: machine) else { return [] }
        var browsers: [BrowserPanel] = []
        for workspace in SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces() {
            var panels = Array(workspace.panels.values)
            workspace._dockSplit?.forEachPanel { _, panel in panels.append(panel) }
            for case let browser as BrowserPanel in panels where browser.websiteDataStore.identifier == store {
                browsers.append(browser)
            }
        }
        return browsers
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
        for browser in browsers(of: machine) { browser.setRemoteProxyEndpoint(endpoint) }
    }
}

/// What sends a mirror page's requests to the owning Mac when the page itself
/// was loaded as written (`http://localhost:P`,
/// ``SupermuxDeviceBrowserRoute/loadsAsWritten(_:dataStoreID:)``).
///
/// Upstream's `RemoteLoopbackRuntimeBridge` does this only on alias pages: its
/// `fetch`, `XMLHttpRequest`, `WebSocket` and `EventSource` send `localhost:Q`
/// to the alias, which the proxy takes to the owning Mac. On an as-written page
/// it stands aside, so every `localhost:Q` call went to this Mac's own port Q
/// (a Supabase on 54321 there, with the page's cookies). This variant, in every
/// loopback frame of a mirror browser, sends a cleartext loopback request on to
/// `localhost:Q` when Q is an as-written port (same-port forward, so cookies on
/// `localhost` reach it too) and through the alias otherwise, as upstream does
/// on an alias page. Like upstream's, it covers script requests, not markup.
/// `BrowserPanel.bindWebView` installs it (`device-mirror-browser-bridge`);
/// ``SupermuxDeviceBrowserRoute/forwardsChanged()`` hands it new ports.
@MainActor
enum SupermuxMirrorLoopbackBridge {
    private static var scriptKey: UInt8 = 0

    /// Adds the bridge to a mirror browser's web view (no-op for any other).
    static func install(on webView: WKWebView) {
        guard let store = webView.configuration.websiteDataStore.identifier,
              let machine = SupermuxDeviceBrowserRoute.machine(forDataStore: store) else { return }
        update(webView, ports: SupermuxDeviceBrowserRoute.asWrittenPorts(of: machine))
    }

    /// Gives the web view's bridge `ports`: the current page at once, and
    /// every page from the next on through a replaced user script.
    static func update(_ webView: WKWebView, ports: Set<Int>) {
        let controller = webView.configuration.userContentController
        let previous = objc_getAssociatedObject(controller, &scriptKey) as? WKUserScript
        // Every frame: a same-origin localhost iframe calls other ports too. The
        // script stands aside at once in any frame not on a loopback host.
        let script = WKUserScript(source: scriptSource(ports: ports), injectionTime: .atDocumentStart, forMainFrameOnly: false)
        if let previous {
            let others = controller.userScripts.filter { $0 !== previous }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        controller.addUserScript(script)
        objc_setAssociatedObject(controller, &scriptKey, script, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let list = ports.sorted().map(String.init).joined(separator: ",")
        // Only a page on a loopback host gets them: any other page could define
        // the setter itself and read the owner's ports.
        webView.evaluateJavaScript("""
        (() => {
          const host = window.location.hostname;
          if (host !== 'localhost' && host !== '127.0.0.1' && host !== '[::1]' && host !== '::1') return true;
          if (window.__cmuxSetMirrorLoopbackPorts) window.__cmuxSetMirrorLoopbackPorts([\(list)]);
          return true;
        })();
        """)
    }

    static func scriptSource(ports: Set<Int>) -> String {
        let list = ports.sorted().map(String.init).joined(separator: ",")
        return """
        (() => {
          const normalizeHost = (host) => {
            let value = String(host || '').trim().toLowerCase();
            if (value.endsWith('.')) value = value.slice(0, -1);
            if (value.startsWith('[') && value.endsWith(']')) value = value.slice(1, -1);
            return value;
          };
          const pageHost = normalizeHost(window.location.hostname);
          if (pageHost !== 'localhost' && pageHost !== '127.0.0.1' && pageHost !== '::1') return true;
          if (window.__cmuxSetMirrorLoopbackPorts) return true;
          const aliasHost = '\(RemoteLoopbackProxyAlias.aliasHost)';
          const exactHosts = new Set(['localhost', '127.0.0.1', '::1', '0.0.0.0']);
          let asWritten = new Set([\(list)]);
          Object.defineProperty(window, '__cmuxSetMirrorLoopbackPorts', {
            value: (ports) => { asWritten = new Set((ports || []).map(Number)); },
          });
          const route = (input) => {
            if (typeof input !== 'string' && !(input instanceof URL)) return input;
            let parsed;
            try { parsed = new URL(input instanceof URL ? input.href : input, document.baseURI); } catch { return input; }
            // Cleartext only, as upstream: TLS checks the URL's host name.
            if (parsed.protocol !== 'http:' && parsed.protocol !== 'ws:') return input;
            const host = normalizeHost(parsed.hostname);
            let alias;
            if (exactHosts.has(host)) {
              if (host !== '0.0.0.0' && asWritten.has(Number(parsed.port || 80))) return input;
              alias = aliasHost;
            } else if (host.endsWith('.localhost') && host.length > '.localhost'.length) {
              alias = `${host.slice(0, -'.localhost'.length)}.${aliasHost}`;
            } else {
              return input;
            }
            parsed.hostname = alias;
            return parsed.href;
          };
          const nativeFetch = window.fetch ? window.fetch.bind(window) : null;
          if (nativeFetch) {
            window.fetch = (input, init) => {
              if (typeof Request !== 'undefined' && input instanceof Request) {
                const routed = route(input.url);
                return nativeFetch(routed !== input.url ? new Request(routed, input) : input, init);
              }
              return nativeFetch(route(input), init);
            };
          }
          const nativeOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
          if (nativeOpen) {
            window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
              return nativeOpen.call(this, method, route(url), ...rest);
            };
          }
          const wrap = (Native) => {
            if (typeof Native !== 'function') return Native;
            const Wrapped = function(url, options) {
              return options === undefined ? new Native(route(url)) : new Native(route(url), options);
            };
            Wrapped.prototype = Native.prototype;
            Object.setPrototypeOf(Wrapped, Native);
            return Wrapped;
          };
          window.WebSocket = wrap(window.WebSocket);
          window.EventSource = wrap(window.EventSource);
          return true;
        })();
        """
    }
}

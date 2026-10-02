#if DEBUG
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import WebKit

/// `supermux.devices.mirror.*` E2E drivers for a device mirror's own browsers
/// (DEBUG builds only): where they send requests, the mirror's layout sync
/// around them, and terminal link opens. Dispatched from
/// ``SupermuxMirrorSocketCommands``; used by
/// `tests/supermux/loopback_mirror_browser_e2e.py` and
/// `tests/supermux/loopback_mirror_local_panels_e2e.py`.
///
/// - `browser_route {workspace_id}` — each browser panel of the workspace:
///   `routes_remotely` (it waits for and uses a workspace proxy, upstream's
///   remote-workspace mode), `proxy_configs` (its WebKit proxy configurations)
///   and `store_identifier` (its website data store; null for the profile's
///   default store).
/// - `browser_proxy {machine, start?}` — the mirror browser proxy for that Mac:
///   the endpoint it hands browsers now (`port`, its credential) and its dial
///   counters; `proxy` is null while it has no endpoint (or where no proxy
///   exists). Starts the proxy's listener when it has none, unless `start` is
///   false: then it only reads, so a listener that restarts on its own can be
///   waited for.
/// - `browser_proxy_fail {machine}` — fails that proxy's listener the way the
///   network stack would; `failed_port` is the port it listened on (null when
///   it was not listening).
/// - `browser_proxy_hold {machine, held}` — while held, that proxy makes no new
///   listener (as when the system cannot make one), so a failed listener stays
///   down; releasing it starts one. `held` is null where no proxy exists.
/// - `browser_store {machine}` — the website data store identifier the route
///   gives that app instance's mirror browsers (any `device:` machine id, also
///   one not connected).
/// - `layout {workspace_id}` — the pane tree as the device layout sync reads it
///   (panel ids, tab order, split directions and ratios), and each panel's kind.
/// - `link_open {workspace_id, surface_id, url, destination: system|cmux|setting}`
///   — a terminal link click from that surface through upstream's
///   `TerminalLinkOpenCoordinator`; the system browser is captured, never opened:
///   `external_url`, and `new_browser_panel_id` for a cmux browser open.
@MainActor
enum SupermuxMirrorBrowserSocket {
    static let methods: Set<Substring> = [
        "browser_route", "browser_proxy", "browser_proxy_fail", "browser_proxy_hold", "browser_store", "layout", "link_open",
    ]

    static func handle(_ method: Substring, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "browser_proxy":
            return browserProxy(try machine(params), starts: params["start"] as? Bool ?? true)
        case "browser_proxy_fail":
            return browserProxyFail(try machine(params))
        case "browser_proxy_hold":
            return browserProxyHold(try machine(params), held: params["held"] as? Bool ?? true)
        case "browser_store":
            return browserStore(try machine(params))
        case "link_open":
            return try await linkOpen(params)
        case "layout":
            return layout(try SupermuxMirrorSocketCommands.mirrorWorkspace(params))
        default:
            return browserRoute(try SupermuxMirrorSocketCommands.mirrorWorkspace(params))
        }
    }

    // MARK: - Browser route

    private static func browserRoute(_ workspace: Workspace) -> [String: Any] {
        let browsers = workspace.panels.values
            .compactMap { $0 as? BrowserPanel }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return [
            "workspace_id": workspace.id.uuidString,
            "is_remote_workspace": workspace.isRemoteWorkspace,
            "browsers": browsers.map(route),
        ]
    }

    private static func route(_ browser: BrowserPanel) -> [String: Any] {
        let store = browser.webView.configuration.websiteDataStore
        var proxyConfigs = 0
        var storeIdentifier: String?
        if #available(macOS 14.0, *) {
            proxyConfigs = store.proxyConfigurations.count
            storeIdentifier = store.identifier?.uuidString
        }
        return [
            "panel_id": browser.id.uuidString,
            "url": browser.currentURL?.absoluteString ?? NSNull(),
            "title": browser.pageTitle,
            // `usesRemoteWorkspaceProxy` is private; this is it for a non-Cloud browser.
            "routes_remotely": browser.refusesProxyAuthenticationChallenges && browser.cloudBrowserMachineID == nil,
            "proxy_configs": proxyConfigs,
            "store_identifier": storeIdentifier ?? NSNull(),
            "store_is_persistent": store.isPersistent,
            "has_pending_remote_navigation": browser.hasPendingRemoteNavigation,
        ]
    }

    // MARK: - Browser proxy

    /// Starts the proxy's listener when it has none (as a mirror browser's
    /// route does), unless `starts` is false.
    private static func browserProxy(_ machine: SurfaceMachineID, starts: Bool) -> [String: Any] {
        let proxies = SupermuxDeviceBrowserProxies.shared
        let endpoint = starts ? proxies.endpoint(for: machine) : proxies.proxy(for: machine)?.endpoint
        guard let endpoint, let proxy = proxies.proxy(for: machine) else {
            return ["machine": machine.rawValue, "proxy": NSNull()]
        }
        return [
            "machine": machine.rawValue,
            "proxy": [
                "port": endpoint.port,
                "username": endpoint.credential.username,
                "password": endpoint.credential.password,
                "owner_dials": proxy.stats.ownerDials,
                "direct_dials": proxy.stats.directDials,
                "failures": proxy.stats.failures,
                "connections": proxy.stats.recentTraces.map { trace -> [String: Any] in
                    [
                        "id": trace.id, "accepted": trace.accepted, "first_byte": trace.firstByte ?? NSNull(),
                        "first_bytes": trace.firstBytes, "decided": trace.decided ?? NSNull(),
                        "target": trace.target, "ended": trace.ended ?? NSNull(), "outcome": trace.outcome,
                        "tunnel_opened": trace.tunnelOpened ?? NSNull(),
                        "first_request_byte": trace.firstRequestByte ?? NSNull(), "request_bytes": trace.requestBytes,
                        "first_response_byte": trace.firstResponseByte ?? NSNull(), "response_bytes": trace.responseBytes,
                    ]
                },
            ] as [String: Any],
        ]
    }

    private static func browserProxyFail(_ machine: SurfaceMachineID) -> [String: Any] {
        guard let proxy = SupermuxDeviceBrowserProxies.shared.proxy(for: machine), let port = proxy.endpoint?.port else {
            return ["machine": machine.rawValue, "failed_port": NSNull()]
        }
        proxy.debugFailListener()
        return ["machine": machine.rawValue, "failed_port": port]
    }

    private static func browserProxyHold(_ machine: SurfaceMachineID, held: Bool) -> [String: Any] {
        guard let proxy = SupermuxDeviceBrowserProxies.shared.proxy(for: machine) else {
            return ["machine": machine.rawValue, "held": NSNull()]
        }
        proxy.debugRefusesListener = held
        if !held { proxy.start() }
        return ["machine": machine.rawValue, "held": held]
    }

    private static func browserStore(_ machine: SurfaceMachineID) -> [String: Any] {
        [
            "machine": machine.rawValue,
            "store_identifier": SupermuxDeviceBrowserRoute.websiteDataStoreID(for: machine)?.uuidString ?? NSNull(),
        ]
    }

    // MARK: - Layout

    private static func layout(_ workspace: Workspace) -> [String: Any] {
        let layout = workspace.deviceWorkspaceLayoutSnapshot()
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return [
            "workspace_id": workspace.id.uuidString,
            "layout": layout ?? NSNull(),
            "panel_kinds": Dictionary(uniqueKeysWithValues: workspace.panels.map {
                ($0.key.uuidString, $0.value.panelType.rawValue)
            }),
        ]
    }

    // MARK: - Link open

    private static func linkOpen(_ params: [String: Any]) async throws -> [String: Any] {
        let workspace = try SupermuxMirrorSocketCommands.mirrorWorkspace(params)
        guard let surfaceID = UUID(uuidString: try SupermuxMirrorSocketCommands.string(params, "surface_id")),
              workspace.panels[surfaceID] != nil else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id is not a panel of this workspace")
        }
        let destination: TerminalLinkOpenRequest.Destination
        switch params["destination"] as? String {
        case "system": destination = .systemBrowser
        case "cmux": destination = .cmuxBrowser
        default: destination = .followsSetting
        }
        let url = try SupermuxMirrorSocketCommands.string(params, "url")
        let browsersBefore = Set(workspace.panels.keys)
        var externalURL: URL?
        let coordinator = TerminalLinkOpenCoordinator(externalOpen: { externalURL = $0; return true }, recordsDiagnostics: false)
        let opened = coordinator.open(TerminalLinkOpenRequest(
            rawValue: url,
            sourceWorkspaceId: workspace.id,
            sourcePanelId: surfaceID,
            workingDirectory: nil,
            focus: false,
            destination: destination
        ))
        // A cmux browser open lands on the next main-actor turn.
        var newBrowser: UUID?
        for _ in 0..<40 where externalURL == nil {
            newBrowser = workspace.panels.first { !browsersBefore.contains($0.key) && $0.value is BrowserPanel }?.key
            if newBrowser != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return [
            "opened": opened,
            "external_url": externalURL?.absoluteString ?? NSNull(),
            "new_browser_panel_id": newBrowser?.uuidString ?? NSNull(),
        ]
    }

    // MARK: - Params

    private static func machine(_ params: [String: Any]) throws -> SurfaceMachineID {
        let machine = SurfaceMachineID(rawValue: try SupermuxMirrorSocketCommands.string(params, "machine"))
        guard machine.isDevice else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "machine must be a device id from supermux.devices.list")
        }
        return machine
    }
}
#endif

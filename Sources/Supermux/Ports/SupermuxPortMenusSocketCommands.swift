#if DEBUG
import CmuxSettingsUI
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// `supermux.devices.ports.chip_open` and `supermux.devices.ports.menus`
/// (DEBUG builds only): E2E drivers for what another Mac's ports offer in the
/// sidebar (`tests/supermux/loopback_port_forward_e2e.py`). Routed from
/// ``SupermuxDevicesSocketCommands`` ahead of ``SupermuxDevicePortsSocketCommands``.
///
/// - `chip_open {workspace_id, port, cmux_browser?}` — a sidebar port chip
///   click on that workspace (a device mirror's through
///   ``SupermuxDevicePortLinks/openChip(_:workspaceID:prefersCmuxBrowser:)``,
///   the `device-mirror-port-chip` touchpoint's call, else upstream's;
///   `is_mirror` when the port is the owning Mac's, `in_mirror` when the
///   workspace is a mirror), with `cmux_browser`
///   standing for the "Open Sidebar Port Links in cmux Browser" setting
///   (default: its value). The default browser and the alert are captured,
///   never shown: `external_url`, `notice`, and `new_browser_panel_id` for a
///   cmux browser open.
/// - `menus {workspace_id?}` — the port menus as they render now: `mirror`,
///   that workspace's "Ports on <Mac>" (null when it is not a device mirror),
///   and `settings`, each Mac's Ports… menu in Settings › Remote Macs. Each
///   port lists its `items` (`SupermuxRemoteMacPortAction` raw values, plus
///   `openInCmuxBrowser`).
@MainActor
enum SupermuxPortMenusSocketCommands {
    static let methods: Set<String> = ["ports.chip_open", "ports.menus"]

    static func handles(_ name: String) -> Bool {
        methods.contains(name)
    }

    static func handle(_ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "ports.chip_open":
            return try chipOpen(params)
        default:
            return [
                "mirror": try mirrorMenu(params) ?? NSNull(),
                "settings": settingsMenus(),
            ]
        }
    }

    // MARK: - Chip click

    private static func chipOpen(_ params: [String: Any]) throws -> [String: Any] {
        let workspace = try SupermuxMirrorSocketCommands.mirrorWorkspace(params)
        guard let port = (params["port"] as? NSNumber)?.intValue, (1...65_535).contains(port) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "port must be 1-65535")
        }
        let prefersCmuxBrowser = params["cmux_browser"] as? Bool
            ?? BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser()
        let panelsBefore = Set(workspace.panels.keys)
        var externalURL: URL?
        var notice: String?
        let isMirror = SupermuxDevicePortLinks.isMirrorChip(workspaceID: workspace.id, port: port)
        let inMirror = SupermuxDevicePortLinks.isMirror(workspaceID: workspace.id)
        if inMirror {
            SupermuxDevicePortLinks.openChip(
                port,
                workspaceID: workspace.id,
                prefersCmuxBrowser: prefersCmuxBrowser,
                openExternally: { externalURL = $0 },
                explain: { notice = $0 }
            )
        } else {
            upstreamChipOpen(port, workspaceID: workspace.id, prefersCmuxBrowser: prefersCmuxBrowser) { externalURL = $0 }
        }
        let newPanel = workspace.panels.keys.first { !panelsBefore.contains($0) }
        return [
            "is_mirror": isMirror,
            "in_mirror": inMirror,
            "external_url": externalURL?.absoluteString ?? NSNull(),
            "notice": notice ?? NSNull(),
            "new_browser_panel_id": newPanel?.uuidString ?? NSNull(),
        ]
    }

    /// Upstream's chip click (`onOpenPort` / `openWorkspaceRowPort` in
    /// `ContentView`) for any other workspace, with the default browser injected.
    private static func upstreamChipOpen(
        _ port: Int, workspaceID: UUID, prefersCmuxBrowser: Bool, openExternally: (URL) -> Void
    ) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        if prefersCmuxBrowser,
           AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?.openBrowser(
               inWorkspace: workspaceID, url: url, preferSplitRight: true, insertAtEnd: true
           ) != nil {
            return
        }
        openExternally(url)
    }

    // MARK: - Menus

    /// The mirror row's "Ports on <Mac>": ``SupermuxMirrorPortsMenuModel``,
    /// which `SupermuxMirrorPortsMenu` renders.
    private static func mirrorMenu(_ params: [String: Any]) throws -> [String: Any]? {
        guard params["workspace_id"] != nil else { return nil }
        let workspace = try SupermuxMirrorSocketCommands.mirrorWorkspace(params)
        guard let model = SupermuxMirrorPortsMenuModel(workspaceID: workspace.id) else { return nil }
        var ports: [[String: Any]] = []
        for (section, list) in [("own", model.ownPorts), ("other", model.otherPorts)] {
            for port in list {
                ports.append([
                    "remote_port": port.remotePort,
                    "label": port.label,
                    "section": section,
                    "items": (port.opensInCmuxBrowser ? ["openInCmuxBrowser"] : []) + port.actions.map(\.rawValue),
                ])
            }
        }
        return [
            "workspace_id": workspace.id.uuidString,
            "machine": model.machine.rawValue,
            "title": model.title,
            "reason": model.reason ?? NSNull(),
            "ports": ports,
            "forward_port": model.offersForwardPort,
        ]
    }

    /// Each Mac's Ports… menu in Settings, from the snapshot
    /// `SupermuxRemoteMacsSettingsCard` renders.
    private static func settingsMenus() -> [[String: Any]] {
        SupermuxComposition.remoteMacsSettings.snapshot().macs.map { mac in
            let shown = mac.showsPortsMenu
            return [
                "machine": mac.id,
                "shown": shown,
                "ports": (shown ? mac.ports : []).filter { !$0.actions.isEmpty }.map { port -> [String: Any] in
                    ["remote_port": port.remotePort, "items": port.actions.map(\.rawValue)]
                },
                "forward_port": shown && mac.canForwardPorts,
            ]
        }
    }
}
#endif

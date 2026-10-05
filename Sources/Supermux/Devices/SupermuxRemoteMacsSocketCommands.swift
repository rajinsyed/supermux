import CmuxSettings
import CmuxSettingsUI
import Foundation
import SupermuxKit

/// `supermux.devices.*` methods for the Settings "Remote Macs" card and the
/// flat-row Mac icon, so E2E tests read and drive exactly what the UI does:
///
/// - `remote_macs_settings {}` — the card's snapshot, plus upstream's
///   discoverability preferences it reports.
/// - `remote_macs_settings_set {setting: auto_mirror|forward_ports|sync_projects|share_push, enabled}`
///   or `{action: show_hidden}` — the card's own actions.
/// - `flat_chips {}` — for every device mirror, the Mac its flat-row icon
///   names, the state it renders (`online` / `connecting` / `offline`), and
///   what is drawn: `style: "icon"`, `symbol`, `help` (the tooltip, with the
///   link's route while connected), `route` (its words, or null), `relayed`
///   (the amber dot) and `placement` (`branch_line`, or `title_line` when the
///   row draws none).
///
/// Each Mac in `remote_macs_settings` carries its row's `route` (the words,
/// null unless connected with one) and `route_is_relayed`.
@MainActor
enum SupermuxRemoteMacsSocketCommands {
    static let methods: Set<String> = ["remote_macs_settings", "remote_macs_settings_set", "flat_chips"]

    struct InvalidParams: Error {
        let message: String
    }

    static func handle(_ name: String, params: [String: Any]) throws -> [String: Any] {
        switch name {
        case "remote_macs_settings": return settingsPayload()
        case "remote_macs_settings_set": return try set(params)
        default: return flatChips()
        }
    }

    private static func settingsPayload() -> [String: Any] {
        let snapshot = SupermuxComposition.remoteMacsSettings.snapshot()
        let keys = DevicesCatalogSection()
        return [
            "auto_mirror": snapshot.autoMirror,
            "sync_projects": snapshot.syncProjects,
            "share_push": snapshot.sharePush,
            "forward_ports": snapshot.forwardPorts,
            "hidden_workspace_count": snapshot.hiddenWorkspaceCount,
            "discovery_enabled": UserDefaults.standard.bool(forKey: keys.discoveryEnabled.userDefaultsKey),
            "incoming_access_enabled": UserDefaults.standard.bool(forKey: keys.incomingAccessEnabled.userDefaultsKey),
            "macs": snapshot.macs.map { mac -> [String: Any] in
                [
                    "machine": mac.id,
                    "name": mac.name,
                    "link": mac.link.rawValue,
                    "detail": mac.detail ?? NSNull(),
                    "route": mac.route?.label ?? NSNull(),
                    "route_is_relayed": mac.route?.isRelayed ?? false,
                    "workspace_count": mac.workspaceCount,
                    "ports": mac.ports.map { port -> [String: Any] in
                        [
                            "remote_port": port.remotePort,
                            "local_port": port.localPort ?? NSNull(),
                            "is_forwarded": port.isForwarded,
                            "line_text": port.lineText,
                            "menu_label": port.menuLabel,
                        ]
                    },
                    "ports_note": mac.portsNote ?? NSNull(),
                ]
            },
        ]
    }

    private static func set(_ params: [String: Any]) throws -> [String: Any] {
        let actions = SupermuxComposition.remoteMacsSettings.actions()
        if params["action"] as? String == "show_hidden" {
            actions.showHiddenWorkspaces()
            return settingsPayload()
        }
        guard let enabled = params["enabled"] as? Bool else {
            throw InvalidParams(message: "enabled (bool) is required, or action: show_hidden")
        }
        switch params["setting"] as? String {
        case "auto_mirror": actions.setAutoMirror(enabled)
        case "forward_ports": actions.setForwardPorts(enabled)
        case "sync_projects": actions.setSyncProjects(enabled)
        case "share_push": actions.setSharePush(enabled)
        default: throw InvalidParams(message: "setting must be auto_mirror, forward_ports, sync_projects or share_push")
        }
        return settingsPayload()
    }

    private static func flatChips() -> [String: Any] {
        let devices = SupermuxComposition.devices.devices
        let settings = SidebarTabItemSettingsSnapshot()
        let chips = SupermuxComposition.deviceWorkspaceIndex.mirrors().compactMap { mirror -> [String: Any]? in
            guard let label = CloudWorkspaceSidebarPresentation.deviceLabel(workspace: mirror.workspace) else { return nil }
            let name = SupermuxFlatRowDeviceChip.macName(fromDeviceWorkspaceLabel: label)
            let state = SupermuxFlatRowDeviceChip.state(ofMacNamed: name, devices: devices)
            let route = SupermuxFlatRowDeviceChip.route(ofMacNamed: name, devices: devices)
            let snapshot = SidebarWorkspaceSnapshotFactory(
                workspace: mirror.workspace,
                settings: settings,
                showsAgentActivity: true
            ).makeSnapshot()
            var chip: [String: Any] = [
                "workspace_id": mirror.workspace.id.uuidString,
                "machine": mirror.ref.machineID,
                "label": label,
                "mac_name": name,
                "chip_state": String(describing: state),
                "placement": SupermuxProjectsSocketPayloads.flatDeviceIconPlacement(snapshot, settings: settings),
            ]
            chip.merge(SupermuxProjectsSocketPayloads.deviceIcon(name: name, state: state, route: route)) { current, _ in current }
            return chip
        }
        return ["chips": chips]
    }
}

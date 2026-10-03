#if DEBUG
import CmuxSimulatorStreamKit
import Foundation

/// A remote-simulator viewer tab as the DEBUG drivers read and drive it. The
/// viewer panel conforms in its own DEBUG extension, so this file builds (and
/// reports no viewers) without it.
@MainActor
protocol SupermuxRemoteSimulatorDebugInspectable: AnyObject {
    /// The viewer's phase, host status, presented frames, last config,
    /// quality and binding.
    func debugState() -> [String: Any]
    /// Runs one driver action (`input`, `control`, `quality`,
    /// `select_device`, `show_here`, `devices`) with the driver's params.
    func debugPerform(_ action: String, params: [String: Any]) async throws -> [String: Any]
}

/// `supermux.devices.mirror.simulator.*` E2E drivers for simulators in device
/// mirrors (DEBUG builds only), dispatched from ``SupermuxDevicesSocketCommands``.
///
/// - `new_action {workspace_id, path: "configured" | "tab_bar"}` — "New
///   Simulator" in that workspace: the configured `cmux.newSimulator` action
///   (File menu, command palette, plus menu, shortcut) on the selected
///   workspace, or the pane tab bar's New Simulator button (the button is
///   installed on the workspace's tab bar first).
/// - `state {include_devices?}` — every Simulator tab in every window: local
///   `SimulatorPanel`s (`class: "local"`) and viewers (`class: "viewer"`, with
///   their state), plus `simulator_panel_count`, `viewer_count` and `app_pid`
///   (the parent of this app's simulator worker processes).
/// - `input {panel_id, event}`, `control {panel_id, action}`, `quality
///   {panel_id, preset}`, `select_device {panel_id, udid}`, `show_here
///   {panel_id}` — the viewer's own controls; `accepted: false` when the panel
///   is not a viewer.
/// - `steal {host_panel_id}` — opens a second loopback stream lane to that
///   host panel and sends `start`, as another device opening the same
///   simulator would.
/// - `simctl_delay {seconds?}` — sets (or reads) the slow-`simctl` hook
///   (``SupermuxSimctlDebugDelay``): every `simctl` spawn of this app's
///   Simulator panels waits that long first; 0 turns it off.
@MainActor
enum SupermuxRemoteSimulatorSocketCommands {
    static let methodPrefix = "mirror.simulator."

    /// The dispatcher answers these `invalid_params`.
    typealias InvalidParams = SupermuxMirrorSocketCommands.InvalidParams

    /// Lanes opened by `steal`, kept open (and drained) until the next steal.
    private static var stolenLanes: [SupermuxRemoteSimulatorLoopbackLane] = []

    /// Whether `name` (after `supermux.devices.`) is one of these drivers.
    static func handles(_ name: String) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle(_ name: String, params: [String: Any]) async throws -> [String: Any] {
        switch name.dropFirst(methodPrefix.count) {
        case "new_action":
            return try newAction(params)
        case "state":
            return await state(includeDevices: params["include_devices"] as? Bool ?? false)
        case "input", "control", "quality", "select_device", "show_here":
            let action = String(name.dropFirst(methodPrefix.count))
            guard let viewer = viewer(try uuid(params, "panel_id")) else {
                return ["accepted": false, "reason": "no_viewer"]
            }
            return try await viewer.debugPerform(action, params: params)
        case "steal":
            return try await steal(hostPanelID: try uuid(params, "host_panel_id"))
        case "simctl_delay":
            let previous = SupermuxSimctlDebugDelay.seconds
            if let seconds = (params["seconds"] as? NSNumber)?.doubleValue {
                SupermuxSimctlDebugDelay.seconds = seconds
            }
            return ["seconds": SupermuxSimctlDebugDelay.seconds, "previous": previous]
        default:
            throw InvalidParams(message: "unknown simulator driver \(name)")
        }
    }

    // MARK: - New Simulator

    private static func newAction(_ params: [String: Any]) throws -> [String: Any] {
        guard let workspace = Workspace.liveWorkspace(id: try uuid(params, "workspace_id")) else {
            throw InvalidParams(message: "workspace_id does not name an open workspace")
        }
        guard let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            throw InvalidParams(message: "workspace has no pane")
        }
        let path = params["path"] as? String ?? "configured"
        switch path {
        case "configured":
            guard let manager = workspace.owningTabManager, let app = AppDelegate.shared else {
                throw InvalidParams(message: "workspace has no window")
            }
            manager.selectWorkspace(workspace)
            let executed = app.executeConfiguredCmuxAction(
                id: CmuxSurfaceTabBarBuiltInAction.newSimulator.configID,
                tabManager: manager
            )
            return ["workspace_id": workspace.id.uuidString, "path": path, "executed": executed]
        case "tab_bar":
            let action = CmuxSurfaceTabBarBuiltInAction.newSimulator
            workspace.applySurfaceTabBarButtons(
                [.builtIn(action)],
                sourcePath: nil,
                globalConfigPath: "",
                terminalCommandSourcePaths: [:],
                workspaceCommands: [:]
            )
            workspace.splitTabBar(workspace.bonsplitController, didRequestCustomAction: action.configID, inPane: pane)
            return ["workspace_id": workspace.id.uuidString, "path": path, "executed": true]
        default:
            throw InvalidParams(message: "path must be configured or tab_bar")
        }
    }

    // MARK: - State

    private static func state(includeDevices: Bool) async -> [String: Any] {
        var rows: [[String: Any]] = []
        var simulatorPanels = 0
        var viewers = 0
        for workspace in SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces() {
            let isMirror = SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace)
            for (panelID, panel) in workspace.panels.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                var row: [String: Any] = [
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelID.uuidString,
                    "is_mirror": isMirror,
                ]
                if let local = panel as? SimulatorPanel {
                    simulatorPanels += 1
                    row["class"] = "local"
                    row["selected_device_id"] = local.selectedDeviceID ?? NSNull()
                } else if let viewer = panel as? SupermuxRemoteSimulatorDebugInspectable {
                    viewers += 1
                    row["class"] = "viewer"
                    row.merge(viewer.debugState()) { _, new in new }
                    if includeDevices {
                        row["devices"] = (try? await viewer.debugPerform("devices", params: [:]))?["devices"] ?? NSNull()
                    }
                } else {
                    continue
                }
                rows.append(row)
            }
        }
        return [
            "app_pid": Int(ProcessInfo.processInfo.processIdentifier),
            "simulator_panel_count": simulatorPanels,
            "viewer_count": viewers,
            "panels": rows,
        ]
    }

    private static func viewer(_ panelID: UUID) -> (any SupermuxRemoteSimulatorDebugInspectable)? {
        for workspace in SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces() {
            if let viewer = workspace.panels[panelID] as? SupermuxRemoteSimulatorDebugInspectable {
                return viewer
            }
        }
        return nil
    }

    // MARK: - Another viewer

    /// Starts a second stream of `hostPanelID`, which supersedes whichever
    /// viewer streamed it (the host's last-writer-wins claim).
    private static func steal(hostPanelID: UUID) async throws -> [String: Any] {
        for lane in stolenLanes { await lane.close() }
        let lane = try SupermuxRemoteSimulatorLoopbackLane.open(panelID: hostPanelID)
        stolenLanes = [lane]
        // 800 is the Data Saver long side; this second viewer only needs to exist.
        let start = SimStreamStartRequest(
            epoch: UInt64(Date().timeIntervalSince1970 * 1000),
            maximumLongSidePixels: 800,
            codecPreferences: [.h264]
        )
        try await lane.send(SimStreamWireCodec().encodeFramed(.start(start)))
        // Drain what the host sends (config, keyframe, state) so the pipe
        // never grows; the host stops on its own once it has no credit.
        Task {
            while (try? await lane.receive()) != nil {}
        }
        return ["stolen": true, "host_panel_id": hostPanelID.uuidString]
    }

    // MARK: - Params

    private static func uuid(_ params: [String: Any], _ key: String) throws -> UUID {
        guard let raw = params[key] as? String, let id = UUID(uuidString: raw) else {
            throw InvalidParams(message: "\(key) must be a UUID")
        }
        return id
    }
}
#endif

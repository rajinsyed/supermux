import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// `supermux.devices.mirror.*` socket methods: E2E drivers and introspection
/// for the fork's device-mirror behaviors, each running the SAME code path as
/// its UI entry point (the `+` menu, ⌘N, ⌘G, the presets bar, the Changes
/// panel's model, the Files resolver). Routed from
/// ``SupermuxDevicesSocketCommands`` (touchpoint #521's lane).
///
/// Methods (params in braces; `window_id` defaults to the preferred window):
/// - `inspect {workspace_id}` — mirror target, run state, local-path actions.
/// - `new_workspace_menu {window_id?}` — the `+` menu's "New Workspace on ▸" rows.
/// - `new_workspace_menu_invoke {machine, window_id?, timeout_seconds?}` — clicks the
///   row whose `row_id` is `machine` (a Mac's machine id, or `this_mac`).
/// - `new_workspace_shortcut {window_id?, timeout_seconds?}` — ⌘N's action.
/// - `run_toggle {workspace_id, via: "shortcut"|"presets_bar"}` — ⌘G / Run.
/// - `preset_launch {workspace_id, name, command}` — a presets-bar chip.
/// - `action_run {workspace_id, action_id}` — a remote project action.
/// - `changes {workspace_id, action: status|stage|unstage|diff|fetch, path?, staged?, open_viewer?}`.
@MainActor
enum SupermuxMirrorSocketCommands {
    static let methodPrefix = "mirror."

    struct InvalidParams: Error {
        let message: String
    }

    /// Runs one `mirror.*` sub-method.
    static func handle(_ method: Substring, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "inspect":
            return inspect(try mirrorWorkspace(params))
        case "new_workspace_menu":
            return ["rows": try menuRows(params).map(row)]
        case "new_workspace_menu_invoke":
            return try await invokeMenuRow(params)
        case "new_workspace_shortcut":
            return try await newWorkspaceShortcut(params)
        case "run_toggle":
            return try runToggle(params)
        case "preset_launch":
            return try await presetLaunch(params)
        case "action_run":
            return try await actionRun(params)
        case "changes":
            return try await SupermuxMirrorChangesSocket.handle(params, workspace: try mirrorWorkspace(params))
        default:
            throw InvalidParams(message: "unknown mirror method \(method)")
        }
    }

    // MARK: - Inspect

    static func inspect(_ workspace: Workspace) -> [String: Any] {
        let target = SupermuxComposition.mirrorResolver.target(for: workspace)
        var payload: [String: Any] = [
            "workspace_id": workspace.id.uuidString,
            "title": workspace.title,
            "is_mirror": target != nil,
            "run": [
                "is_running": SupermuxComposition.runCoordinator.isRunning(workspaceId: workspace.id),
            ],
            "local_path_actions": SupermuxMirrorLocalPathActions.describe(workspace),
        ]
        if let target {
            payload["target"] = [
                "machine": target.ref.machineID,
                "remote_workspace_id": target.remoteWorkspaceID,
                "device_name": target.deviceName,
                "is_connected": target.isConnected,
                "remote_directory": target.remoteDirectory ?? NSNull(),
                "remote_project_id": target.remoteProjectID ?? NSNull(),
            ] as [String: Any]
            payload["presets_bar_host_label"] = target.presetsBarHostLabel
            payload["changes_open_diff_hint"] = SupermuxMirrorChangesPanel.openDiffUnavailableHelp(for: target)
        }
        return payload
    }

    // MARK: - New Workspace on ▸ <Mac>

    private static func menuRows(_ params: [String: Any]) throws -> [NSMenuItem] {
        guard let app = AppDelegate.shared else { throw SupermuxDeviceError.windowUnavailable }
        let manager = try tabManager(params)
        guard let context = app.mainWindowContext(for: manager), let store = context.cmuxConfigStore,
              let menu = app.makeNewWorkspaceContextMenu(context: context, cmuxConfigStore: store) else {
            return []
        }
        let parent = menu.items.first { $0.identifier?.rawValue == SupermuxNewWorkspaceDeviceMenu.parentIdentifier }
        return parent?.submenu?.items ?? []
    }

    private static func row(_ item: NSMenuItem) -> [String: Any] {
        let machine = (item.representedObject as? SupermuxNewWorkspaceDeviceMenuTarget.Request)?.machine.rawValue
        return [
            "row_id": rowID(item) ?? NSNull(),
            "machine": machine ?? NSNull(),
            "title": item.title,
            "is_enabled": item.isEnabled,
            "is_checked": item.state == .on,
            "badge": item.badge?.stringValue ?? NSNull(),
        ]
    }

    /// A row's id: the identifier after the menu's prefix (a Mac's machine id).
    private static func rowID(_ item: NSMenuItem) -> String? {
        let prefix = SupermuxNewWorkspaceDeviceMenu.itemIdentifierPrefix
        guard let raw = item.identifier?.rawValue, raw.hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count))
    }

    /// Clicks the row whose `row_id` is `machine`. A Mac's row waits for the
    /// new mirror; any other row (This Mac) for a new local workspace.
    private static func invokeMenuRow(_ params: [String: Any]) async throws -> [String: Any] {
        let machine = try string(params, "machine")
        let manager = try tabManager(params)
        guard let item = try menuRows(params).first(where: { rowID($0) == machine }) else {
            throw InvalidParams(message: "no New Workspace on ▸ row for \(machine)")
        }
        guard item.isEnabled, let action = item.action else {
            return ["invoked": false, "reason": "row is disabled"]
        }
        let isMacRow = item.representedObject is SupermuxNewWorkspaceDeviceMenuTarget.Request
        return try await awaitingNewWorkspace(isMacRow ? .mirror : .local, in: manager, timeout: timeout(params)) {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    private static func newWorkspaceShortcut(_ params: [String: Any]) async throws -> [String: Any] {
        let manager = try tabManager(params)
        return try await awaitingNewWorkspace(.mirror, in: manager, timeout: timeout(params)) {
            AppDelegate.shared?.performNewWorkspaceAction(tabManager: manager, debugSource: "supermux.socket.newWorkspace") ?? false
        }
    }

    /// What a New Workspace entry point is expected to create.
    private enum NewWorkspaceKind {
        /// A mirror of a workspace created on another Mac.
        case mirror
        /// A workspace on this Mac.
        case local
    }

    /// Runs `trigger`, then waits for a new workspace of `kind` in `manager`'s
    /// window while sampling every workspace title there (so a provisional
    /// "Cloud VM" row would be caught).
    private static func awaitingNewWorkspace(
        _ kind: NewWorkspaceKind,
        in manager: TabManager,
        timeout: Duration,
        trigger: () -> Bool
    ) async throws -> [String: Any] {
        let index = SupermuxComposition.deviceWorkspaceIndex
        let before = Set(manager.tabs.map(\.id))
        var titles: [String] = []
        let invoked = trigger()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            titles.append(contentsOf: manager.tabs.filter { !before.contains($0.id) }.map(\.title))
            let created = manager.tabs.first { tab in
                guard !before.contains(tab.id), !tab.panels.isEmpty else { return false }
                switch kind {
                case .mirror: return index.isDeviceMirror(tab) && index.ref(forLocal: tab) != nil
                case .local: return !index.isDeviceMirror(tab)
                }
            }
            if let created {
                var payload = SupermuxDevicesSocketPayloads(devices: SupermuxComposition.devices, index: index)
                    .localWorkspace(created)
                payload["invoked"] = invoked
                payload["is_device_mirror"] = index.isDeviceMirror(created)
                payload["remote_workspace_id"] = index.ref(forLocal: created)?.workspaceID ?? NSNull()
                payload["observed_titles"] = Array(Set(titles)).sorted()
                return payload
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return ["invoked": invoked, "timed_out": true, "observed_titles": Array(Set(titles)).sorted()]
    }

    // MARK: - Run, presets, actions

    private static func runToggle(_ params: [String: Any]) throws -> [String: Any] {
        let workspace = try mirrorWorkspace(params)
        let coordinator = SupermuxComposition.runCoordinator
        let consumed: Bool
        if (params["via"] as? String) == "presets_bar" {
            consumed = coordinator.toggleRun(workspace: workspace)
        } else {
            guard let manager = workspace.owningTabManager else { throw SupermuxDeviceError.windowUnavailable }
            manager.selectWorkspace(workspace)
            consumed = coordinator.toggleRun(tabManager: manager)
        }
        return ["consumed": consumed]
    }

    private static func presetLaunch(_ params: [String: Any]) async throws -> [String: Any] {
        let workspace = try mirrorWorkspace(params)
        guard let target = SupermuxComposition.mirrorResolver.target(for: workspace) else {
            throw InvalidParams(message: "workspace_id is not a device mirror")
        }
        let preset = SupermuxTerminalPreset(name: try string(params, "name"), command: try string(params, "command"))
        switch try await SupermuxComposition.mirrorPresets.launch(preset, in: target) {
        case .remotePreset(let id, let terminalID):
            return ["outcome": "remote_preset", "preset_id": id, "terminal_id": terminalID ?? NSNull()]
        case .typedCommand(let terminalID):
            return ["outcome": "typed_command", "terminal_id": terminalID]
        }
    }

    private static func actionRun(_ params: [String: Any]) async throws -> [String: Any] {
        let workspace = try mirrorWorkspace(params)
        guard let target = SupermuxComposition.mirrorResolver.target(for: workspace),
              let projectID = target.remoteProjectID else {
            throw InvalidParams(message: "workspace_id is not a device mirror of a project workspace")
        }
        switch try await SupermuxComposition.mirrorProjectActions.run(
            actionID: try string(params, "action_id"), projectID: projectID, on: target
        ) {
        case .openedURL(let url): return ["outcome": "open_url", "url": url.absoluteString]
        case .ranCommand: return ["outcome": "command"]
        }
    }

    // MARK: - Params

    static func mirrorWorkspace(_ params: [String: Any]) throws -> Workspace {
        guard let id = UUID(uuidString: try string(params, "workspace_id")),
              let workspace = Workspace.liveWorkspace(id: id) else {
            throw InvalidParams(message: "workspace_id does not name an open workspace")
        }
        return workspace
    }

    private static func tabManager(_ params: [String: Any]) throws -> TabManager {
        guard let app = AppDelegate.shared else { throw SupermuxDeviceError.windowUnavailable }
        if let raw = params["window_id"] as? String {
            guard let id = UUID(uuidString: raw), let manager = app.tabManagerFor(windowId: id) else {
                throw InvalidParams(message: "window_id does not name an open window")
            }
            return manager
        }
        guard let manager = app.preferredMainWindowContextForWorkspaceCreation(debugSource: "supermux.mirror")?.tabManager else {
            throw SupermuxDeviceError.windowUnavailable
        }
        return manager
    }

    static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw InvalidParams(message: "\(key) is required")
        }
        return value
    }

    private static func timeout(_ params: [String: Any]) -> Duration {
        let seconds = min(max((params["timeout_seconds"] as? NSNumber)?.doubleValue ?? 30, 1), 120)
        return .milliseconds(Int(seconds * 1000))
    }
}

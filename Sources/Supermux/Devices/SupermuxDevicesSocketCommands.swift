import CmuxControlSocket
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// `supermux.devices.*` v2 socket methods: introspection and automation of
/// the device foundation for E2E tests (`cmux rpc supermux.devices.list '{}'`).
/// Routed by the `supermux-devices-socket` touchpoint in
/// `TerminalController+ControlSocketAsync.swift` (SUPERMUX-TOUCHPOINTS.md #521),
/// on the async socket lane, so long awaits never block the main thread.
///
/// Methods: `list {include_capabilities?}`, `bindings {}`,
/// `open {machine, remote_workspace_id, focus?, window_id?, create_starter_terminal?}`,
/// `create_workspace {machine, title?, cwd?, focus?, window_id?}`,
/// `await_open {machine, remote_workspace_id, timeout_seconds?, focus?, window_id?}`,
/// `local_projects {}` (this Mac's `projects.list` host payload + origin map),
/// and (DEBUG builds only) `request {machine, method, params?, timeout_seconds?}`,
/// `bind {workspace_id, machine, remote_workspace_id}` and `unbind {workspace_id}` (test hooks for the
/// export filter and restart-stable bindings without a second Mac). The device-mirror methods
/// (`close_mirror`, `unhide`, `hidden`, `set_auto_mirror`, `reconcile`) are handled by
/// ``SupermuxDeviceMirrorSocketCommands``, plus the notification /
/// phone-push hooks in ``SupermuxDeviceNotificationSocketCommands`` (`push_decisions`,
/// `notification_records`, `notification_overrides`, `phone_push_debug`, `phone_push_probe`,
/// `phone_push_share_now`).
@MainActor
enum SupermuxDevicesSocketCommands {
    nonisolated static let methodPrefix = "supermux.devices."

    /// Whether the fork owns `method`.
    nonisolated static func handles(_ method: String) -> Bool {
        method.hasPrefix(methodPrefix)
    }

    private struct InvalidParams: Error {
        let message: String
    }

    /// Runs one method and returns its typed result for the socket encoder.
    static func handle(method: String, params wireParams: [String: JSONValue]) async -> ControlCallResult {
        let params = wireParams.mapValues(\.foundationObject)
        let devices = SupermuxComposition.devices
        let payloads = SupermuxDevicesSocketPayloads(devices: devices, index: SupermuxComposition.deviceWorkspaceIndex)
        do {
            let result: [String: Any]
            let name = String(method.dropFirst(methodPrefix.count))
            if SupermuxDeviceMirrorSocketCommands.methods.contains(name) {
                return await SupermuxDeviceMirrorSocketCommands.handle(name, params: params, payloads: payloads)
            }
            switch name {
            case "list":
                result = await list(params, devices: devices, payloads: payloads)
            case "bindings":
                result = payloads.bindings()
            case "local_projects":
                result = await localProjects()
            case "open":
                result = payloads.opened(try await open(params))
            case "create_workspace":
                result = payloads.opened(try await createWorkspace(params))
            case "await_open":
                result = payloads.opened(try await awaitOpen(params))
            case "request":
                #if DEBUG
                result = try await request(params, devices: devices)
                #else
                return unknownMethod()
                #endif
            case "bind", "unbind":
                #if DEBUG
                result = try setBinding(params, bound: method.hasSuffix(".bind"), payloads: payloads)
                #else
                return unknownMethod()
                #endif
            #if DEBUG
            case let name where SupermuxDeviceNotificationSocketCommands.handles(name):
                result = try await SupermuxDeviceNotificationSocketCommands.handle(String(name), params)
            #endif
            case let name where SupermuxProjectsSocketCommands.handles(String(name)):
                // Projects across Macs (plans/supermux-remote-workspaces/PROJECTS-API.md).
                result = try await SupermuxProjectsSocketCommands.handle(String(name), params: params)
            default:
                return unknownMethod()
            }
            guard let value = JSONValue(foundationObject: result) else {
                return .err(code: "internal_error", message: "The result could not be encoded.", data: nil)
            }
            return .ok(value)
        } catch let error as InvalidParams {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch let error as SupermuxDeviceError {
            return .err(code: error.code, message: error.localizedDescription, data: nil)
        } catch {
            return .err(code: "request_failed", message: error.localizedDescription, data: nil)
        }
    }

    // MARK: - Methods

    private static func list(
        _ params: [String: Any],
        devices: SupermuxDevices,
        payloads: SupermuxDevicesSocketPayloads
    ) async -> [String: Any] {
        let includeCapabilities = bool(params, "include_capabilities") ?? false
        var entries: [[String: Any]] = []
        for device in devices.devices {
            let capabilities = includeCapabilities && device.isConnected
                ? await devices.hostCapabilities(on: device.machine)
                : devices.cachedHostCapabilities(on: device.machine)
            entries.append(payloads.device(device, capabilities: capabilities))
        }
        return [
            "revision": devices.revision,
            "auto_mirror": SupermuxComposition.devicesSettings.autoMirror,
            "auto_mirror_state": SupermuxDeviceMirrorSocketCommands.coordinatorState(SupermuxComposition.deviceMirrorCoordinator),
            "devices": entries,
        ]
    }

    private static func open(_ params: [String: Any]) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let ref = SupermuxRemoteWorkspaceRef(
            machine: try machine(params),
            workspaceID: try required(params, "remote_workspace_id")
        )
        return try await SupermuxComposition.deviceWorkspaceOpener.openMirror(
            of: ref,
            in: try tabManager(params),
            focus: bool(params, "focus") ?? false,
            createStarterTerminalIfEmpty: bool(params, "create_starter_terminal") ?? false
        )
    }

    private static func createWorkspace(_ params: [String: Any]) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        try await SupermuxComposition.deviceWorkspaceOpener.createWorkspace(
            on: try machine(params),
            title: string(params, "title"),
            workingDirectory: string(params, "cwd") ?? string(params, "working_directory"),
            in: try tabManager(params),
            focus: bool(params, "focus") ?? false
        )
    }

    private static func awaitOpen(_ params: [String: Any]) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let ref = SupermuxRemoteWorkspaceRef(
            machine: try machine(params),
            workspaceID: try required(params, "remote_workspace_id")
        )
        let seconds = min(max(number(params, "timeout_seconds") ?? 30, 1), 600)
        return try await SupermuxComposition.deviceWorkspaceOpener.openWhenAvailable(
            ref,
            in: try tabManager(params),
            focus: bool(params, "focus") ?? false,
            timeout: .milliseconds(Int(seconds * 1000))
        )
    }

    /// This Mac's projects as other Macs and the phone see them (the exact
    /// `mobile.supermux.projects.list` host payload, with `git_remote_url`),
    /// plus the local UI's observable origin map.
    private static func localProjects() async -> [String: Any] {
        let hosted = await TerminalController.shared.v2SupermuxProjectsList(params: [:])
        let remotes = SupermuxComposition.projectGitRemotes
        let local = SupermuxComposition.projectsModel.projects.map { project -> [String: Any] in
            [
                "id": project.id.uuidString,
                "name": project.name,
                "root_path": project.rootPath,
                "git_remote_url": remotes.url(for: project.id) ?? NSNull(),
                "git_remote_identity": remotes.identity(for: project.id) ?? NSNull(),
            ]
        }
        var hostPayload: Any = NSNull()
        if case .ok(let payload) = hosted { hostPayload = payload }
        return ["host_payload": hostPayload, "local": local]
    }

    #if DEBUG
    private static func request(_ params: [String: Any], devices: SupermuxDevices) async throws -> [String: Any] {
        let method = try required(params, "method")
        guard params["params"] == nil || params["params"] is NSNull || params["params"] is [String: Any] else {
            throw InvalidParams(message: "params must be an object")
        }
        let timeout = number(params, "timeout_seconds").map { Duration.milliseconds(Int(min(max($0, 1), 600) * 1000)) }
        let result = try await devices.request(
            method,
            params: params["params"] as? [String: Any] ?? [:],
            on: try machine(params),
            timeout: timeout
        )
        return ["result": result]
    }

    private static func setBinding(
        _ params: [String: Any],
        bound: Bool,
        payloads: SupermuxDevicesSocketPayloads
    ) throws -> [String: Any] {
        guard let id = UUID(uuidString: try required(params, "workspace_id")),
              let workspace = Workspace.liveWorkspace(id: id) else {
            throw InvalidParams(message: "workspace_id does not name an open workspace")
        }
        let index = SupermuxComposition.deviceWorkspaceIndex
        if bound {
            index.bind(workspace, to: SupermuxRemoteWorkspaceRef(
                machine: try machine(params),
                workspaceID: try required(params, "remote_workspace_id")
            ))
        } else {
            index.unbind(workspace)
        }
        var payload = payloads.localWorkspace(workspace)
        payload["is_device_mirror"] = index.isDeviceMirror(workspace)
        return payload
    }
    #endif

    // MARK: - Params

    private static func machine(_ params: [String: Any]) throws -> SurfaceMachineID {
        let raw = try required(params, "machine")
        let machine = SurfaceMachineID(rawValue: raw)
        guard machine.isDevice else {
            throw InvalidParams(message: "machine must be a device id (device:<uuid>@<tag>) from supermux.devices.list")
        }
        return machine
    }

    private static func tabManager(_ params: [String: Any]) throws -> TabManager {
        guard let app = AppDelegate.shared else { throw SupermuxDeviceError.windowUnavailable }
        if let raw = string(params, "window_id") {
            guard let id = UUID(uuidString: raw), let manager = app.tabManagerFor(windowId: id) else {
                throw InvalidParams(message: "window_id does not name an open window")
            }
            return manager
        }
        guard let manager = app.preferredMainWindowContextForWorkspaceCreation(debugSource: "supermux.devices")?.tabManager else {
            throw SupermuxDeviceError.windowUnavailable
        }
        return manager
    }

    private static func required(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = string(params, key) else { throw InvalidParams(message: "\(key) is required") }
        return value
    }

    private static func string(_ params: [String: Any], _ key: String) -> String? {
        guard let value = (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func bool(_ params: [String: Any], _ key: String) -> Bool? {
        params[key] as? Bool
    }

    private static func number(_ params: [String: Any], _ key: String) -> Double? {
        (params[key] as? NSNumber)?.doubleValue
    }

    private static func unknownMethod() -> ControlCallResult {
        .err(
            code: "method_not_found",
            message: String(localized: "socket.error.unknownMethod", defaultValue: "Unknown method"),
            data: nil
        )
    }
}

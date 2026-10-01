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
/// export filter and restart-stable bindings without a second Mac), and `link {machine, action:
/// stop|restore|stall|status, busy?, method?, seconds?}` (holds a link down, then redials it; holds one
/// loopback host request), and `terminal_mouse_drag {surface_id, from, to}`
/// (a real Ghostty mouse drag across a terminal, for the mirror input E2E), and `user_close
/// {workspace_id | workspace_ids, answer?}` (a user close with its confirmations pre-answered),
/// `reopen_closed_workspace {}` and `hold_remote_closes {enabled}`
/// (``SupermuxDeviceMirrorCloseSocketCommands``). The device-mirror methods
/// (`close_mirror`, `unhide`, `hidden`, `set_auto_mirror`, `reconcile`) are handled by
/// ``SupermuxDeviceMirrorSocketCommands``, plus the notification /
/// phone-push hooks in ``SupermuxDeviceNotificationSocketCommands`` (`push_decisions`,
/// `notification_records`, `notification_overrides`, `notification_mark_unread`,
/// `notification_indicators`, `notification_click`, `phone_push_debug`,
/// `phone_push_probe`, `phone_push_share_now`), the `mirror.*` mirror-behavior drivers
/// (``SupermuxMirrorSocketCommands``), the `terminal_sizing.*` size preference drivers
/// (``SupermuxTerminalSizingSocketCommands``), and the `new_worktree.*` New Worktree
/// sheet drivers (`SupermuxNewWorktreeSocketCommands`).
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
            case "terminal_mouse_drag":
                #if DEBUG
                result = try terminalMouseDrag(params)
                #else
                return unknownMethod()
                #endif
            case "link":
                #if DEBUG
                result = try setLink(params, devices: devices)
                #else
                return unknownMethod()
                #endif
            #if DEBUG
            case let name where SupermuxDeviceNotificationSocketCommands.handles(name):
                result = try await SupermuxDeviceNotificationSocketCommands.handle(String(name), params)
            case let name where SupermuxDeviceTerminalCloseSocketCommands.handles(name): result = try SupermuxDeviceTerminalCloseSocketCommands.handle(name, params)
            case let name where SupermuxDeviceMirrorCloseSocketCommands.handles(name): result = try SupermuxDeviceMirrorCloseSocketCommands.handle(name, params)
            case let name where SupermuxTerminalSizingSocketCommands.handles(name):
                result = try SupermuxTerminalSizingSocketCommands.handle(name, params: params)
            #endif
            case let name where SupermuxRemoteMacsSocketCommands.methods.contains(name):
                // Settings "Remote Macs" card and the flat-row device chip.
                result = try SupermuxRemoteMacsSocketCommands.handle(name, params: params)
            case let name where SupermuxProjectsSocketCommands.handles(String(name)):
                // Projects across Macs (plans/supermux-remote-workspaces/PROJECTS-API.md).
                result = try await SupermuxProjectsSocketCommands.handle(String(name), params: params)
            case let sub where sub.hasPrefix("new_worktree."):
                // Device-aware New Worktree sheet drivers (DEBUG builds only).
                #if DEBUG
                result = try await SupermuxNewWorktreeSocketCommands.handle(
                    String(sub.dropFirst(SupermuxNewWorktreeSocketCommands.methodPrefix.count)),
                    params: params,
                    payloads: payloads
                )
                #else
                return unknownMethod()
                #endif
            case let sub where sub.hasPrefix(SupermuxMirrorSocketCommands.methodPrefix):
                // Mirror-behavior E2E drivers (DEBUG builds only).
                #if DEBUG
                result = try await SupermuxMirrorSocketCommands.handle(
                    sub.dropFirst(SupermuxMirrorSocketCommands.methodPrefix.count), params: params
                )
                #else
                return unknownMethod()
                #endif
            default:
                return unknownMethod()
            }
            guard let value = JSONValue(foundationObject: result) else {
                return .err(code: "internal_error", message: "The result could not be encoded.", data: nil)
            }
            return .ok(value)
        } catch let error as InvalidParams {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch let error as SupermuxMirrorSocketCommands.InvalidParams {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch let error as SupermuxRemoteMacsSocketCommands.InvalidParams {
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

    /// Drags the mouse across a terminal through its real Ghostty view (the
    /// path a trackpad drag takes), from and to fractions of the view's size.
    /// With mouse tracking on, the terminal reports the drag to its program;
    /// on a device mirror those reports cross to the other Mac.
    private static func terminalMouseDrag(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["surface_id"] as? String, let surfaceID = UUID(uuidString: raw),
              let surface = TerminalController.shared.terminalSocketTarget(surfaceID: surfaceID)?.surface else {
            throw InvalidParams(message: "surface_id must name a terminal")
        }
        let view = surface.hostedView
        func point(_ key: String) throws -> NSPoint {
            guard let pair = params[key] as? [Any], pair.count == 2,
                  let x = (pair[0] as? NSNumber)?.doubleValue, let y = (pair[1] as? NSNumber)?.doubleValue else {
                throw InvalidParams(message: "\(key) must be [x, y] fractions of the terminal")
            }
            return NSPoint(x: view.bounds.width * x, y: view.bounds.height * y)
        }
        let selected = view.debugSimulateSelection(from: try point("from"), to: try point("to"))
        return ["surface_id": surfaceID.uuidString, "has_selection": selected]
    }

    /// `link {machine, action: "stop" | "restore" | "stall" | "status", busy?,
    /// method?, seconds?}`: holds a device link down (tearing down its client
    /// like a transport loss, but without the immediate redial) or dials it
    /// again, so E2E can drop the link under an in-flight request and watch
    /// availability change live. `busy: "<method>"` on a restore makes the
    /// loopback host answer the new connection's first `<method>` request
    /// after its sync fetch `server_busy`; `stall` makes it hold its next
    /// `method` request for `seconds` (default 30) before answering it
    /// (``SupermuxDeviceLoopbackHostAcceptor``). Every action answers the
    /// link's phase, the loopback connections admitted since launch (a redial
    /// adds one) and whether a stall is still armed.
    private static func setLink(_ params: [String: Any], devices: SupermuxDevices) throws -> [String: Any] {
        let machine = try machine(params)
        guard let link = devices.provider(for: machine)?.link else {
            throw SupermuxDeviceError.unknownDevice(machine.rawValue)
        }
        switch try required(params, "action") {
        case "stop": link.stop()
        case "restore":
            SupermuxDeviceLoopbackHostAcceptor.busyMethodForNextConnection = params["busy"] as? String
            link.refresh()
        case "stall":
            SupermuxDeviceLoopbackHostAcceptor.stalledRequest = (
                method: try required(params, "method"),
                seconds: min(max(number(params, "seconds") ?? 30, 1), 600)
            )
        case "status": break
        default: throw InvalidParams(message: "action must be stop, restore, stall or status")
        }
        return [
            "machine": machine.rawValue,
            "phase": String(describing: link.phase),
            "connections_admitted": SupermuxDeviceLoopbackHostAcceptor.admittedConnections,
            "stall_armed": SupermuxDeviceLoopbackHostAcceptor.stalledRequest != nil,
        ]
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

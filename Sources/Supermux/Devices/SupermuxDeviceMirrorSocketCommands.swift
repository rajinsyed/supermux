import CmuxControlSocket
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// The device-mirror `supermux.devices.*` socket methods (auto-mirror, close
/// semantics, hidden set), dispatched from ``SupermuxDevicesSocketCommands``:
///
/// - `close_mirror {workspace_id, action: "close_on_mac" | "hide"}` — a
///   user close without this Mac's confirmations (closes it on its Mac; waits
///   for the send, `pending_on_mac` says whether it still waits for that Mac)
///   or Hide Here.
/// - `unhide {machine?, remote_workspace_id?}` — unhide one ref, one device's
///   refs, or (no params) every hidden ref; auto-mirror reopens them.
/// - `hidden {}` — the hidden set, and `pending_remote_closes` (closed here,
///   not yet on their Mac).
/// - `set_auto_mirror {enabled}` — the `supermux.devices.autoMirror` setting.
/// - `reconcile {}` — run an auto-mirror pass now and report its state.
/// - `fail_next_open {machine, remote_workspace_id}` (DEBUG builds only) — the
///   next auto-mirror open of that ref fails, as a dropped link would.
@MainActor
enum SupermuxDeviceMirrorSocketCommands {
    static let methods: Set<String> = {
        var methods: Set<String> = ["close_mirror", "unhide", "hidden", "set_auto_mirror", "reconcile"]
        #if DEBUG
        methods.insert("fail_next_open")
        #endif
        return methods
    }()

    static func handle(_ name: String, params: [String: Any], payloads: SupermuxDevicesSocketPayloads) async -> ControlCallResult {
        do {
            let result: [String: Any]
            switch name {
            case "close_mirror": result = try await closeMirror(params, payloads: payloads)
            case "unhide": result = unhide(params)
            case "hidden": result = hidden()
            case "set_auto_mirror": result = try setAutoMirror(params)
            #if DEBUG
            case "fail_next_open": result = try failNextOpen(params)
            #endif
            default: result = reconcile()
            }
            guard let value = JSONValue(foundationObject: result) else {
                return .err(code: "internal_error", message: "The result could not be encoded.", data: nil)
            }
            return .ok(value)
        } catch let error as SupermuxDeviceError {
            return .err(code: error.code, message: error.localizedDescription, data: nil)
        } catch {
            return .err(code: "request_failed", message: error.localizedDescription, data: nil)
        }
    }

    /// The mirror named by `workspace_id`, and the remote workspace it shows.
    private static func mirror(_ params: [String: Any]) throws -> (Workspace, SupermuxRemoteWorkspaceRef) {
        guard let raw = params["workspace_id"] as? String, let id = UUID(uuidString: raw),
              let workspace = Workspace.liveWorkspace(id: id) else {
            throw invalid("workspace_id does not name an open workspace")
        }
        let index = SupermuxComposition.deviceWorkspaceIndex
        guard index.isDeviceMirror(workspace), let ref = index.ref(forLocal: workspace) else {
            throw invalid("workspace_id is not a device mirror")
        }
        return (workspace, ref)
    }

    private static func closeMirror(_ params: [String: Any], payloads: SupermuxDevicesSocketPayloads) async throws -> [String: Any] {
        let (workspace, ref) = try mirror(params)
        let id = workspace.id
        let closer = SupermuxComposition.deviceMirrorCloser
        var payload = payloads.localWorkspace(workspace)
        payload["machine"] = ref.machineID
        payload["remote_workspace_id"] = ref.workspaceID
        switch params["action"] as? String {
        case "close_on_mac":
            try await closer.closeOnMac(workspace)
            payload["action"] = "close_on_mac"
            payload["pending_on_mac"] = closer.pendingRemoteCloses.contains(ref)
        case "hide":
            guard closer.hideHere(workspace) else { throw invalid("the mirror could not be closed") }
            payload["action"] = "hide"
        default:
            throw invalid("action must be close_on_mac or hide")
        }
        payload["closed"] = Workspace.liveWorkspace(id: id) == nil
        return payload
    }

    private static func unhide(_ params: [String: Any]) -> [String: Any] {
        let machine = (params["machine"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ref = machine.flatMap { machine in
            (params["remote_workspace_id"] as? String).map { SupermuxRemoteWorkspaceRef(machineID: machine, workspaceID: $0) }
        }
        let removed = SupermuxDeviceMirrorsGlue.unhide(machineID: machine, ref: ref)
        return ["unhidden": removed.map(refPayload)]
    }

    private static func hidden() -> [String: Any] {
        let refs = SupermuxComposition.hiddenRemoteWorkspaces.refs.sorted { $0.description < $1.description }
        let pending = SupermuxComposition.deviceMirrorCloser.pendingRemoteCloses.sorted { $0.description < $1.description }
        return ["hidden": refs.map(refPayload), "pending_remote_closes": pending.map(refPayload)]
    }

    private static func setAutoMirror(_ params: [String: Any]) throws -> [String: Any] {
        guard let enabled = params["enabled"] as? Bool else { throw invalid("enabled (bool) is required") }
        SupermuxComposition.devicesSettings.autoMirror = enabled
        SupermuxComposition.deviceMirrorCoordinator.scheduleReconcile()
        return ["auto_mirror": SupermuxComposition.devicesSettings.autoMirror]
    }

    #if DEBUG
    private static func failNextOpen(_ params: [String: Any]) throws -> [String: Any] {
        guard let machine = (params["machine"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
              let workspaceID = params["remote_workspace_id"] as? String, !workspaceID.isEmpty else {
            throw invalid("machine and remote_workspace_id are required")
        }
        let ref = SupermuxRemoteWorkspaceRef(machineID: machine, workspaceID: workspaceID)
        SupermuxComposition.deviceMirrorCoordinator.debugFailNextOpen(of: ref)
        return refPayload(ref)
    }
    #endif

    private static func reconcile() -> [String: Any] {
        let coordinator = SupermuxComposition.deviceMirrorCoordinator
        coordinator.reconcileNow()
        return coordinatorState(coordinator)
    }

    /// The coordinator's diagnostic state (also part of `supermux.devices.list`).
    static func coordinatorState(_ coordinator: SupermuxDeviceMirrorCoordinator) -> [String: Any] {
        let plan = coordinator.lastPlan
        return [
            "auto_mirror": SupermuxComposition.devicesSettings.autoMirror,
            // The setting as passes apply it (off in Remote Host Mode).
            "auto_mirror_effective": coordinator.effectiveAutoMirror,
            "ready": SupermuxDeviceMirrorCoordinator.appIsReady(),
            "reconcile_count": coordinator.reconcileCount,
            "is_opening": coordinator.isOpening,
            "busy": coordinator.busyRefs.sorted { $0.description < $1.description }.map(refPayload),
            "last_plan": [
                "opens": plan.opens.map(refPayload),
                "closes": plan.closes.map { close -> [String: Any] in
                    var payload = refPayload(close.ref)
                    payload["workspace_id"] = close.localWorkspaceID.uuidString
                    payload["reason"] = close.reason.rawValue
                    return payload
                },
                "unhide": plan.unhide.map(refPayload),
                "follow_up_after": plan.followUpAfter ?? NSNull(),
            ] as [String: Any],
            "last_open_error": coordinator.lastOpenError ?? NSNull(),
        ]
    }

    static func refPayload(_ ref: SupermuxRemoteWorkspaceRef) -> [String: Any] {
        ["machine": ref.machineID, "remote_workspace_id": ref.workspaceID]
    }

    private static func invalid(_ message: String) -> SupermuxDeviceError {
        .hostRejected(code: "invalid_params", message: message)
    }
}

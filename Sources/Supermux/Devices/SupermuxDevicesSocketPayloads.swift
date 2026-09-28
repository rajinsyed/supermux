import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// JSON shapes of the `supermux.devices.*` socket methods (see
/// plans/supermux-remote-workspaces/FOUNDATION-API.md). Pure builders over
/// the facade and index; no side effects.
@MainActor
struct SupermuxDevicesSocketPayloads {
    let devices: SupermuxDevices
    let index: SupermuxDeviceWorkspaceIndex

    func device(_ device: SupermuxDevice, capabilities: Set<String>?) -> [String: Any] {
        let records = devices.records(on: device.machine)
        return [
            "machine": device.machine.rawValue,
            "device_id": device.instance.deviceID,
            "tag": device.instance.tag,
            "name": device.displayName,
            "link_state": device.linkState.rawValue,
            "link_detail": device.linkDetail ?? NSNull(),
            "has_fetched_records": device.hasFetchedRecords,
            "is_loopback": device.isLoopback,
            "capabilities": capabilities.map { Array($0).sorted() } ?? NSNull(),
            "record_count": records.count,
            "records": records.map { record($0, on: device.machine) },
        ]
    }

    func record(_ record: WorkspaceSyncRecord, on machine: SurfaceMachineID) -> [String: Any] {
        let ref = SupermuxRemoteWorkspaceRef(machine: machine, record: record)
        return [
            "id": record.id,
            "title": record.title,
            "is_selected": record.isSelected,
            "current_directory": record.currentDirectory ?? NSNull(),
            "terminal_count": record.terminals.count,
            "supermux_project_id": record.supermuxProjectID ?? NSNull(),
            "supermux_branch": record.supermuxBranch ?? NSNull(),
            "supermux_activity": record.supermuxActivity ?? NSNull(),
            "supermux_unread_count": record.supermuxUnreadCount ?? NSNull(),
            "mirror_workspace_id": index.localWorkspace(showing: ref)?.id.uuidString ?? NSNull(),
        ]
    }

    func localWorkspace(_ workspace: Workspace) -> [String: Any] {
        let manager = workspace.owningTabManager
        let windowID = manager.flatMap { AppDelegate.shared?.windowId(for: $0) }
        return [
            "workspace_id": workspace.id.uuidString,
            "stable_id": workspace.stableId.uuidString,
            "title": workspace.title,
            "window_id": windowID?.uuidString ?? NSNull(),
            "is_selected": manager?.selectedTabId == workspace.id,
        ]
    }

    func mirror(_ mirror: SupermuxDeviceMirror) -> [String: Any] {
        var payload = localWorkspace(mirror.workspace)
        payload["machine"] = mirror.ref.machineID
        payload["remote_workspace_id"] = mirror.ref.workspaceID
        payload["is_bound"] = mirror.isBound
        payload["remote_title"] = devices.record(for: mirror.ref)?.title ?? NSNull()
        payload["status"] = mirrorStatus(mirror.workspace)
        return payload
    }

    func opened(_ opened: SupermuxDeviceWorkspaceOpener.Opened) -> [String: Any] {
        var payload = localWorkspace(opened.workspace)
        payload["machine"] = opened.ref.machineID
        payload["remote_workspace_id"] = opened.ref.workspaceID
        payload["reused"] = opened.reused
        return payload
    }

    func bindings() -> [String: Any] {
        let live = SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces()
        let liveStableIDs = Set(live.map(\.stableId))
        let stored = index.storedBindings
            .sorted { $0.value.boundAt < $1.value.boundAt }
            .map { stableID, binding -> [String: Any] in
                [
                    "stable_id": stableID.uuidString,
                    "workspace_id": binding.workspaceID.uuidString,
                    "machine": binding.ref.machineID,
                    "remote_workspace_id": binding.ref.workspaceID,
                    "bound_at": binding.boundAt.timeIntervalSince1970,
                    "is_live": liveStableIDs.contains(stableID),
                ]
            }
        return [
            "mirrors": index.mirrors().map(mirror),
            "hidden": SupermuxComposition.hiddenRemoteWorkspaces.refs
                .sorted { $0.description < $1.description }
                .map(SupermuxDeviceMirrorSocketCommands.refPayload),
            "stored": stored,
            "local_workspaces": live.map { workspace -> [String: Any] in
                var payload = localWorkspace(workspace)
                payload["is_device_mirror"] = index.isDeviceMirror(workspace)
                return payload
            },
        ]
    }
}

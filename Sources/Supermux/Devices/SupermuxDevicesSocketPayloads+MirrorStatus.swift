import CmuxSidebar
import Foundation
import SupermuxKit

extension SupermuxDevicesSocketPayloads {
    /// What a mirror row shows, as the E2E sees it: the overlays every
    /// consumer reads (activity through the shared resolver, branch) and
    /// the remote pills / progress / log / customization written into the
    /// mirror workspace.
    func mirrorStatus(_ workspace: Workspace) -> [String: Any] {
        let prefix = SupermuxDeviceStatusProjector.remoteStatusKeyPrefix
        let remoteEntries = workspace.sidebarStatusEntriesInDisplayOrder()
            .filter { $0.key.hasPrefix(prefix) }
            .map { entry -> [String: Any] in
                [
                    "key": String(entry.key.dropFirst(prefix.count)),
                    "value": entry.value,
                    "icon": entry.icon ?? NSNull(),
                    "color": entry.color ?? NSNull(),
                ]
            }
        let remoteLog = workspace.logEntries.last { $0.source == SupermuxDeviceStatusProjector.remoteLogSource }
        return [
            "activity": SupermuxWorkspaceActivityResolver.activity(for: workspace).rawValue,
            "branch": workspace.supermuxSidebarBranch ?? NSNull(),
            "status_entries": remoteEntries,
            "progress": workspace.progress.map { ["value": $0.value, "label": $0.label ?? NSNull()] as [String: Any] } ?? NSNull(),
            "log": remoteLog.map { ["message": $0.message, "level": $0.level.rawValue] } ?? NSNull(),
            "custom_color": workspace.customColor ?? NSNull(),
            "description": workspace.customDescription ?? NSNull(),
            "is_pinned": workspace.isPinned,
            "has_overlay": SupermuxComposition.deviceStatusProjector.status(forLocal: workspace.id) != nil,
        ]
    }

    /// What the mirror status projection left in ANY local workspace: its
    /// remote pill keys, remote log line and progress bar. A workspace that
    /// stopped being a mirror must carry none of them.
    func projectedRemoteStatus(_ workspace: Workspace) -> [String: Any] {
        let prefix = SupermuxDeviceStatusProjector.remoteStatusKeyPrefix
        let remoteLog = workspace.logEntries.last { $0.source == SupermuxDeviceStatusProjector.remoteLogSource }
        return [
            "status_keys": workspace.statusEntries.keys.filter { $0.hasPrefix(prefix) }.sorted(),
            "log": remoteLog?.message ?? NSNull(),
            "progress": workspace.progress.map { ["value": $0.value, "label": $0.label ?? NSNull()] as [String: Any] } ?? NSNull(),
        ]
    }
}

import CMUXMobileCore
import CmuxSidebar
import Foundation

/// Writes a mirror's remote status into its local `Workspace`: the remote
/// pills (under ``SupermuxDeviceStatusProjector/remoteStatusKeyPrefix``), the
/// progress bar, the latest log line, and the remote's color, description and
/// pin. Each field is written only when the remote value changed since the
/// last projection (or on first sight), so a local edit on the mirror holds
/// until the owning Mac changes that field again.
@MainActor
struct SupermuxDeviceMirrorStatusWriter {
    let workspace: Workspace

    func apply(_ status: SupermuxDeviceMirrorStatus, previous: SupermuxDeviceMirrorStatus?) {
        if previous?.statusEntries != status.statusEntries { applyStatusEntries(status.statusEntries) }
        if previous == nil || previous?.progress != status.progress { applyProgress(status.progress) }
        if previous == nil || previous?.log != status.log { applyLog(status.log) }
        applyCustomization(status, previous: previous)
    }

    // MARK: - Pills

    private func applyStatusEntries(_ remote: [WorkspaceSyncRecord.SupermuxStatusEntry]) {
        let prefix = SupermuxDeviceStatusProjector.remoteStatusKeyPrefix
        var wanted: [String: SidebarStatusEntry] = [:]
        for (index, entry) in remote.enumerated() {
            let key = prefix + entry.key
            wanted[key] = SidebarStatusEntry(
                key: key,
                value: entry.value,
                icon: entry.icon,
                color: entry.color,
                priority: entry.priority ?? 0,
                // Deterministic and descending: keeps the host's display order
                // among equal priorities without churning on every sync.
                timestamp: Date(timeIntervalSinceReferenceDate: -Double(index))
            )
        }
        for key in workspace.statusEntries.keys where key.hasPrefix(prefix) && wanted[key] == nil {
            workspace.removeStatusEntry(forKey: key)
        }
        for (key, entry) in wanted where workspace.statusEntries[key] != entry {
            workspace.setStatusEntry(entry, key: key, panelId: nil)
        }
    }

    // MARK: - Progress and log

    private func applyProgress(_ remote: WorkspaceSyncRecord.SupermuxProgress?) {
        let next = remote.map { SidebarProgressState(value: min(max($0.value, 0), 1), label: $0.label) }
        if workspace.progress != next { workspace.progress = next }
    }

    private func applyLog(_ remote: WorkspaceSyncRecord.SupermuxLog?) {
        let source = SupermuxDeviceStatusProjector.remoteLogSource
        var entries = workspace.logEntries.filter { $0.source != source }
        if let remote {
            entries.append(SidebarLogEntry(
                message: remote.message,
                level: remote.level.flatMap(SidebarLogLevel.init(rawValue:)) ?? .info,
                source: source,
                timestamp: Date()
            ))
        }
        if entries != workspace.logEntries { workspace.logEntries = entries }
    }

    // MARK: - Color, description, pin (remote -> local)

    private func applyCustomization(_ status: SupermuxDeviceMirrorStatus, previous: SupermuxDeviceMirrorStatus?) {
        guard let manager = workspace.owningTabManager else { return }
        if previous == nil || previous?.customColorHex != status.customColorHex,
           workspace.customColor != status.customColorHex {
            manager.setTabColor(tabId: workspace.id, color: status.customColorHex)
        }
        if previous == nil || previous?.customDescription != status.customDescription,
           workspace.customDescription != status.customDescription {
            manager.setCustomDescription(tabId: workspace.id, description: status.customDescription)
        }
        if previous == nil || previous?.isPinned != status.isPinned, workspace.isPinned != status.isPinned {
            manager.setPinned(workspace, pinned: status.isPinned)
        }
    }
}

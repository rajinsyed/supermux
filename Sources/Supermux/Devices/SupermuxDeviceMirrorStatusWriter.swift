import CMUXMobileCore
import CmuxSidebar
import Foundation
import SupermuxKit

/// Writes a mirror's remote status into its local `Workspace`: the remote
/// pills (under ``SupermuxDeviceStatusProjector/remoteStatusKeyPrefix``), the
/// progress bar, the latest log line, and the remote's color, description and
/// pin. Each field is written only when the remote value changed since the
/// last projection (or on first sight), so a local edit on the mirror holds
/// until the owning Mac changes that field again. The color, description and
/// pin compare against `customizationBaseline`, the remote values last applied
/// (persisted with the binding, so the promise also holds across restarts).
@MainActor
struct SupermuxDeviceMirrorStatusWriter {
    let workspace: Workspace

    func apply(
        _ status: SupermuxDeviceMirrorStatus,
        previous: SupermuxDeviceMirrorStatus?,
        customizationBaseline: SupermuxMirrorCustomization?
    ) {
        if previous?.statusEntries != status.statusEntries { applyStatusEntries(status.statusEntries) }
        if previous == nil || previous?.progress != status.progress { applyProgress(status.progress) }
        if previous == nil || previous?.log != status.log { applyLog(status.log) }
        applyCustomization(status.customization, baseline: customizationBaseline)
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

    private func applyCustomization(_ remote: SupermuxMirrorCustomization, baseline: SupermuxMirrorCustomization?) {
        guard let manager = workspace.owningTabManager else { return }
        if Self.changed(\.colorHex, in: remote, since: baseline), workspace.customColor != remote.colorHex {
            manager.setTabColor(tabId: workspace.id, color: remote.colorHex)
        }
        if Self.changed(\.description, in: remote, since: baseline), workspace.customDescription != remote.description {
            manager.setCustomDescription(tabId: workspace.id, description: remote.description)
        }
        if Self.changed(\.isPinned, in: remote, since: baseline), workspace.isPinned != remote.isPinned {
            manager.setPinned(workspace, pinned: remote.isPinned)
        }
    }

    /// Whether the remote changed `field` since `baseline` (always on first sight).
    private static func changed<Value: Equatable>(
        _ field: KeyPath<SupermuxMirrorCustomization, Value>,
        in remote: SupermuxMirrorCustomization,
        since baseline: SupermuxMirrorCustomization?
    ) -> Bool {
        guard let baseline else { return true }
        return baseline[keyPath: field] != remote[keyPath: field]
    }
}

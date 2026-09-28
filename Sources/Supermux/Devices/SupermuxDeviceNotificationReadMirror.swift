import CmuxCloud
import Foundation

/// Host read → viewer read. When another Mac reads, clears or supersedes a
/// notification, its feed row turns read (`read_by` "mac"); the local copy on
/// the mirror pane is marked read too, so stale unread counts, Dock badges and
/// "needs input" rows do not pile up here.
///
/// No echo: marking the local copy read makes the hub acknowledge the row, and
/// the sync skips rows the host already reports read
/// (`CloudNotificationSyncReducer.recordRead`), so nothing goes back.
@MainActor
enum SupermuxDeviceNotificationReadMirror {
    /// Runs after each accepted feed (`device-notification-parity` fence).
    static func mirrorHostReads(of provider: DeviceSurfaceProvider) {
        guard let store = AppDelegate.shared?.notificationStore else { return }
        let ids = localRecordsToMarkRead(
            machineID: provider.machine.rawValue,
            rows: provider.notificationFeed.rows,
            notifications: store.notifications
        )
        guard !ids.isEmpty else { return }
        #if DEBUG
        cmuxDebugLog("supermux.device.notification.hostRead machine=\(provider.machine.rawValue) marking=\(ids.count)")
        #endif
        store.markNotificationFeedRead(ids: ids)
    }

    /// Unread local records whose feed row the host reports read.
    static func localRecordsToMarkRead(
        machineID: String,
        rows: [CloudVMNotificationRow],
        notifications: [TerminalNotification]
    ) -> Set<UUID> {
        let readRowIDs = Set(rows.lazy
            .filter { $0.isRead(by: DeviceNotificationFeed.clientID) }
            .map(\.id))
        guard !readRowIDs.isEmpty else { return [] }
        var ids = Set<UUID>()
        for notification in notifications where !notification.isRead {
            guard let key = notification.correlationKey,
                  CloudNotificationCorrelation.matches(key, machineID: machineID, notificationIDs: readRowIDs) else { continue }
            ids.insert(notification.id)
        }
        return ids
    }
}

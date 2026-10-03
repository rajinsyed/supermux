import CmuxCloud
import Foundation

/// Host read → viewer read. When another Mac reads, clears or supersedes a
/// notification, its feed row turns read (`read_by` "mac"); the local copy on
/// the mirror pane is marked read too, so stale unread counts, Dock badges and
/// "needs input" rows do not pile up here.
///
/// Only a row that turned read SINCE the previous feed counts. A row the host
/// already reported read stays read there forever, and applying it on every
/// feed would silently undo the user's Mark as Unread on the local copy (which
/// is local only) the next time that Mac's feed changes. The previous feed's
/// read rows are persisted (``SupermuxNotificationReadBaseline``), so a
/// relaunch does not undo it either; reads made there while this Mac was away
/// still apply.
///
/// No echo: marking the local copy read makes the hub acknowledge the row, and
/// the sync skips rows the host already reports read
/// (`CloudNotificationSyncReducer.recordRead`), so nothing goes back.
@MainActor
enum SupermuxDeviceNotificationReadMirror {
    /// Runs after each accepted feed (`device-notification-parity` fence).
    static func mirrorHostReads(of provider: DeviceSurfaceProvider) {
        guard let store = AppDelegate.shared?.notificationStore else { return }
        let machineID = provider.machine.rawValue
        let newlyRead = SupermuxComposition.notificationReadBaseline.newlyRead(
            readRowIDs(in: provider.notificationFeed.rows),
            on: machineID
        )
        let ids = localRecordsToMarkRead(
            machineID: machineID,
            readRowIDs: newlyRead,
            notifications: store.notifications
        )
        guard !ids.isEmpty else { return }
        #if DEBUG
        cmuxDebugLog("supermux.device.notification.hostRead machine=\(machineID) marking=\(ids.count)")
        #endif
        store.markNotificationFeedRead(ids: ids)
    }

    /// Ids of the rows the host reports read.
    static func readRowIDs(in rows: [CloudVMNotificationRow]) -> Set<String> {
        Set(rows.lazy
            .filter { $0.isRead(by: DeviceNotificationFeed.clientID) }
            .map(\.id))
    }

    /// Unread local records whose feed row is among `readRowIDs`.
    static func localRecordsToMarkRead(
        machineID: String,
        readRowIDs: Set<String>,
        notifications: [TerminalNotification]
    ) -> Set<UUID> {
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

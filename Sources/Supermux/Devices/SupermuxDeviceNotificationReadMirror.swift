import CmuxCloud
import Foundation

/// Host read → viewer read. When another Mac reads, clears or supersedes a
/// notification, its feed row turns read (`read_by` "mac"); the local copy on
/// the mirror pane is marked read too, so stale unread counts, Dock badges and
/// "needs input" rows do not pile up here, and a focused mirror pane's ring
/// goes away with it.
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
        clearFocusedRings(afterReading: ids, in: store)
    }

    /// A read on the other Mac also ends the focused pane's ring here, which a
    /// feed read alone keeps (upstream clears it only on a click or typing).
    /// A pane that still has an unread record keeps it: that newer record set
    /// the pane's single indicator, and its own read ends it later. Used in
    /// both directions (the host side: `supermuxNotificationFeedMarkRead`).
    static func clearFocusedRings(afterReading readIDs: Set<UUID>, in store: TerminalNotificationStore) {
        for notification in store.notifications where readIDs.contains(notification.id) {
            guard let surfaceId = notification.surfaceId,
                  !store.hasUnreadNotification(forTabId: notification.tabId, surfaceId: surfaceId) else { continue }
            store.clearFocusedReadIndicator(forTabId: notification.tabId, surfaceId: surfaceId)
        }
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

/// Viewer read → host ring. When another of the user's Macs reads its copy,
/// the ack arrives here as `notification.feed.mark_read` from an admitted Mac
/// peer; besides upstream's record read, the focused pane's ring ends here too
/// (the reverse of ``SupermuxDeviceNotificationReadMirror/mirrorHostReads(of:)``).
/// A phone's read keeps upstream's semantics: the ring stays until a click or
/// typing on this Mac.
extension TerminalController {
    /// `notification.feed.mark_read` (`device-mac-read-clears-host-ring` fence).
    func supermuxNotificationFeedMarkRead(
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext?
    ) -> V2CallResult {
        guard SupermuxMobilePeerPolicy.isAdmittedMacPeer(executionContext) else {
            return v2MobileNotificationFeedMarkRead(params: params)
        }
        let store = TerminalNotificationStore.shared
        let unreadBefore = Set(store.notifications.lazy.filter { !$0.isRead }.map(\.id))
        let result = v2MobileNotificationFeedMarkRead(params: params)
        let newlyRead = Set(store.notifications.lazy.filter { $0.isRead && unreadBefore.contains($0.id) }.map(\.id))
        SupermuxDeviceNotificationReadMirror.clearFocusedRings(afterReading: newlyRead, in: store)
        return result
    }
}

import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Keeps a restored device mirror pane's notifications when its link comes
/// back.
///
/// Session restore puts a mirror's notifications on the restored placeholder
/// pane. On reconnect upstream materializes a live pane beside it and closes
/// the placeholder (`DeviceSurfaceProvider.reconnectRestoredPanes`), and
/// closing a pane clears its notifications, which the device sync then
/// acknowledges to the owning Mac as read. Without this, a relaunch dropped
/// every mirrored notification (and a Mark as Unread with it) and read it on
/// the other Mac. Called by the `device-restored-pane-notifications` fence
/// right before the placeholder closes: its notifications move to the live
/// pane, keeping their read state.
///
/// Session restore does not keep a notification's origin, so a moved copy
/// whose correlation key names a device gets `.deviceMac` back: the viewer
/// must never count it as its own (phone badge) or forward it to the phone.
///
/// The move goes through the store's own `restoreSessionNotifications` (the
/// store has no other way to change a notification's pane), so it has that
/// call's side effects for the mirror workspace: local notifications still
/// queued for it are dropped and its delivered system banners are withdrawn.
/// Device rows are delivered synchronously, never queued, and closing the
/// placeholder used to withdraw those banners anyway.
@MainActor
enum SupermuxRestoredMirrorNotifications {
    static func carry(fromPanel placeholder: UUID, toPanel live: UUID, inWorkspace workspaceID: UUID) {
        guard let store = AppDelegate.shared?.notificationStore else { return }
        let workspaceNotifications = store.notifications.filter { $0.tabId == workspaceID }
        guard workspaceNotifications.contains(where: { $0.isOnPanel(placeholder) }) else { return }
        let moved = workspaceNotifications.map { notification in
            notification.isOnPanel(placeholder) ? notification.supermuxMoved(from: placeholder, to: live) : notification
        }
        store.restoreSessionNotifications(moved, forTabId: workspaceID)
    }
}

private extension TerminalNotification {
    func isOnPanel(_ panelID: UUID) -> Bool {
        surfaceId == panelID || panelId == panelID
    }

    /// This notification on `live` instead of `placeholder`, with its device
    /// origin restored from the correlation key.
    func supermuxMoved(from placeholder: UUID, to live: UUID) -> TerminalNotification {
        let machineID = correlationKey.flatMap(CloudNotificationCorrelation.parse)?.machineID
        let deviceMachine = machineID.flatMap { SurfaceMachineID(rawValue: $0).isDevice ? $0 : nil }
        return TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId == placeholder ? live : surfaceId,
            panelId: panelId == placeholder ? live : panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            correlationKey: correlationKey,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: createdAt,
            isRead: isRead,
            paneFlash: paneFlash,
            scrollPosition: scrollPosition,
            clickAction: clickAction,
            replyShape: replyShape,
            soundContext: soundContext,
            origin: deviceMachine.map { .deviceMac(machineID: $0) } ?? origin,
            project: project
        )
    }
}

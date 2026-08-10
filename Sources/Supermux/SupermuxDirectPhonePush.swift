import CmuxNotifications
import Foundation
import SupermuxKit

/// App-target adapter from terminal notifications to the package-owned APNs service.
@MainActor
struct SupermuxDirectPhonePush {
    private let service: SupermuxPhonePushService

    init(service: SupermuxPhonePushService) {
        self.service = service
    }

    func forward(notification: TerminalNotification, badgeCount: Int, hideContent: Bool) {
        let message = SupermuxPhonePushMessage(
            kind: .notify,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            acceptsTextReply: notification.replyShape == .text,
            workspaceID: notification.tabId.uuidString,
            surfaceID: (notification.surfaceId ?? notification.panelId)?.uuidString,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            macDeviceID: MobileHostIdentity.deviceID(),
            notificationID: notification.id.uuidString,
            badgeCount: badgeCount,
            hideContent: hideContent
        )
        Task { await service.forward(message) }
    }

    func forwardDismissed(ids: [String], badgeCount: Int) {
        let message = SupermuxPhonePushMessage(
            kind: .dismiss,
            dismissedIDs: ids,
            badgeCount: badgeCount
        )
        Task { await service.forward(message) }
    }
}

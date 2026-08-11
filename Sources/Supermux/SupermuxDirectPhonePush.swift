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
        let tabName = AppDelegate.shared?
            .tabTitlesByTabId(for: [notification.tabId])[notification.tabId]
        let message = SupermuxPhonePushMessage(
            kind: .notify,
            title: notification.title,
            // An empty subtitle becomes the provenance line (`project · tab`),
            // so the banner answers "which repo, which terminal?" without the
            // user unlocking anything. A subtitle the agent set is content and
            // is left alone — same rule the macOS banner follows.
            subtitle: Self.subtitle(for: notification, tabName: tabName),
            body: notification.body,
            acceptsTextReply: notification.replyShape == .text,
            workspaceID: notification.tabId.uuidString,
            surfaceID: (notification.surfaceId ?? notification.panelId)?.uuidString,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            macDeviceID: MobileHostIdentity.deviceID(),
            notificationID: notification.id.uuidString,
            badgeCount: badgeCount,
            hideContent: hideContent,
            project: notification.project,
            tabName: tabName
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

    /// The banner's subtitle: whatever the notification already carries, or the
    /// project/tab provenance line when it carries nothing.
    private static func subtitle(
        for notification: TerminalNotification,
        tabName: String?
    ) -> String {
        if let existing = SupermuxNotificationProvenance.normalized(notification.subtitle) {
            return existing
        }
        return SupermuxNotificationProvenance.line(
            projectName: notification.project?.name,
            tabName: tabName
        ) ?? ""
    }
}

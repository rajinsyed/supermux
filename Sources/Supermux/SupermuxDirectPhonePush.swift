import CmuxCloud
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

    /// The direct lane's single entry from the notification store: decides
    /// (``SupermuxPhoneForwardGate/directVerdict(for:focusedPaneAlreadyVisible:admission:)``:
    /// never a record mirrored from another Mac, never the pane a present
    /// user is watching, and upstream's own enabled + `onlyWhenAway`
    /// admission), then forwards.
    ///
    /// - Parameters:
    ///   - upstreamRelayAttempted: Whether upstream's relay lane forwarded it
    ///     too (recorded for DEBUG introspection only).
    ///   - badgeCount: The phone-facing unread count (mirrored records excluded).
    func deliver(
        notification: TerminalNotification,
        focusedPaneAlreadyVisible: Bool,
        upstreamRelayAttempted: Bool,
        badgeCount: Int
    ) {
        let client = PhonePushClient.shared
        let verdict = SupermuxPhoneForwardGate.directVerdict(
            for: notification,
            focusedPaneAlreadyVisible: focusedPaneAlreadyVisible,
            admission: client.currentAdmission()
        )
        #if DEBUG
        SupermuxPhonePushDecisionLog.shared.record(.init(
            notificationID: notification.id,
            workspaceID: notification.tabId,
            surfaceID: notification.surfaceId,
            title: notification.title,
            originKind: notification.origin.kind,
            upstreamRelayAttempted: upstreamRelayAttempted,
            direct: verdict,
            badgeCount: badgeCount,
            recordedAt: Date()
        ))
        #endif
        guard verdict == .forward else { return }
        forward(
            notification: notification,
            badgeCount: badgeCount,
            hideContent: client.configuration().hideContent
        )
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
            macInstanceTag: MobileHostIdentity.instanceTag(),
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

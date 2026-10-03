import Foundation

/// Phone-facing decisions for notifications mirrored from another Mac.
///
/// The Mac that runs the agent is the one that pushes (DESIGN.md decision 8).
/// A viewer Mac records another Mac's notification as `.deviceMac` on the
/// local mirror pane and keeps every LOCAL effect (banner, sound, sidebar
/// unread, Dock badge), but it never forwards that record to the phone and
/// leaves it out of every phone-facing badge. Otherwise the phone gets two
/// banners with different ids (so `apns-collapse-id` cannot fold them), a tap
/// that opens a mirror of a mirror, and a badge that counts one notification
/// once per Mac: every Mac reports only its OWN unread count, and the phone
/// badges the total over every Mac (`SupermuxPhoneBadgeLedger`).
@MainActor
enum SupermuxPhoneForwardGate {
    /// The direct-APNs lane's decision for one notification.
    enum DirectVerdict: String, Sendable {
        /// Handed to the direct APNs service (a no-op without credentials or phones).
        case forward
        /// Mirrored from another Mac; that Mac pushes it.
        case skipDeviceMirror = "skip_device_mirror"
        /// The exact pane is on screen for a user who is at this Mac.
        case skipFocusedPane = "skip_focused_pane"
        /// Phone forwarding is turned off on this Mac.
        case skipDisabled = "skip_disabled"
        /// `onlyWhenAway` mode and the user is at this Mac.
        case skipMacActive = "skip_mac_active"
    }

    /// Whether `origin` is a record mirrored from another of the user's Macs.
    static func isMirroredFromDevice(_ origin: TerminalNotificationOrigin) -> Bool {
        if case .deviceMac = origin { return true }
        return false
    }

    /// Whether upstream's relay lane (`PhonePushClient`) may forward it.
    static func allowsUpstreamRelay(for notification: TerminalNotification) -> Bool {
        !isMirroredFromDevice(notification.origin)
    }

    /// The direct lane's decision: origin first, then the exact focused pane,
    /// then upstream's own forwarding admission (enabled + `onlyWhenAway`).
    static func directVerdict(
        for notification: TerminalNotification,
        focusedPaneAlreadyVisible: Bool,
        admission: PhonePushAdmission
    ) -> DirectVerdict {
        if isMirroredFromDevice(notification.origin) { return .skipDeviceMirror }
        if focusedPaneAlreadyVisible { return .skipFocusedPane }
        switch admission {
        case .allowed: return .forward
        case .suppressedMacActive: return .skipMacActive
        case .forwardingDisabled, .unknown: return .skipDisabled
        }
    }

    /// This Mac's share of the phone badge: every unread record except those
    /// mirrored from another Mac (that Mac reports them itself; the phone
    /// adds every Mac's share up).
    static func phoneBadgeCount(unreadCount: Int, notifications: [TerminalNotification]) -> Int {
        let mirroredUnread = notifications.reduce(into: 0) { count, notification in
            if !notification.isRead, isMirroredFromDevice(notification.origin) { count += 1 }
        }
        return max(0, unreadCount - mirroredUnread)
    }

    /// Dismissal ids a phone could hold from THIS Mac: ids of mirrored
    /// records are dropped (this Mac never pushed them). Ids no longer in the
    /// store are kept, since their origin is unknown.
    static func phoneFacingDismissIDs(_ ids: [String], in notifications: [TerminalNotification]) -> [String] {
        let mirroredIDs = Set(notifications.lazy
            .filter { isMirroredFromDevice($0.origin) }
            .map(\.id.uuidString))
        guard !mirroredIDs.isEmpty else { return ids }
        return ids.filter { !mirroredIDs.contains($0) }
    }
}

extension TerminalNotificationStore {
    /// The phone-facing unread count (``SupermuxPhoneForwardGate/phoneBadgeCount(unreadCount:notifications:)``),
    /// used by every badge this Mac sends a phone: forwarded pushes, the
    /// `notification.badge` event, dismissals and `notification.reconcile`.
    var supermuxPhoneBadgeCount: Int {
        SupermuxPhoneForwardGate.phoneBadgeCount(
            unreadCount: unreadNotificationCount,
            notifications: notifications
        )
    }
}

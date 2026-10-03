// SUPERMUX:begin supermux-phone-badge-total (the phone badge is every Mac's total: the foreground Mac's live count joins the per-Mac ledger the notification service extension keeps — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import SupermuxMobileCore

/// The app's side of ``SupermuxPhoneBadgeLedger``.
///
/// Every Mac reports only its own unread count: the foreground Mac over the
/// live session (`notification.reconcile`, `notification.badge`,
/// `notification.dismissed`), every Mac in its direct pushes. The notification
/// service extension records each push's count per Mac build (device id and
/// instance tag); this records the foreground build's fresher live count in
/// the same ledger, so the badge the app sets is the total over every Mac
/// build rather than the foreground build's share.
extension MobileShellComposite {
    /// The badge for the foreground build's own unread `count`: that count
    /// recorded for the foreground build, plus every other build's latest
    /// count. `count` itself without a foreground Mac identity or a shared
    /// ledger.
    func supermuxPhoneBadgeTotal(foregroundCount count: Int) -> Int {
        guard let foregroundMacDeviceID,
              let ledger = SupermuxPhoneBadgeLedger.shared() else { return count }
        return ledger.total(
            recording: count,
            forMacDeviceID: foregroundMacDeviceID,
            instanceTag: activeMacInstanceTag
        )
    }

    /// Drops a forgotten build's share of the badge and applies the new
    /// total, so a Mac the phone no longer knows cannot hold the badge up
    /// forever.
    func supermuxForgetPhoneBadge(macDeviceID: String, instanceTag: String?) {
        guard let ledger = SupermuxPhoneBadgeLedger.shared() else { return }
        deliveredNotificationClearer.setBadgeCount(ledger.total(forgetting: macDeviceID, instanceTag: instanceTag))
    }
}
// SUPERMUX:end supermux-phone-badge-total

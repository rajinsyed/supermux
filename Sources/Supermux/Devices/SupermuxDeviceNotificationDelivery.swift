import CmuxCloud
import Foundation

/// Wraps upstream's delivery of another Mac's notification onto a local mirror
/// pane (`DeviceSurfaceProvider.deliverNotification`) with two parity rules,
/// through the `device-notification-parity` touchpoint:
///
/// 1. **Remote project.** The row's project from the other Mac's feed is
///    remembered under the record's correlation key, so the banner and the
///    local feed show that Mac's project.
/// 2. **Rate-limited rows retry soon.** A declined row (over the admission
///    budget) schedules a short retry instead of waiting for the next feed
///    event (``SupermuxDeviceNotificationRetry``).
///
/// A copy that lands on the focused mirror pane is unread like any other, so
/// the host's record turns read only when the copy is read here (a click or
/// typing in the pane), never on arrival.
@MainActor
enum SupermuxDeviceNotificationDelivery {
    static func deliver(
        _ row: CloudVMNotificationRow,
        to target: CloudNotificationDeliveryTarget,
        via provider: DeviceSurfaceProvider
    ) -> CloudNotificationDeliveryOutcome {
        let key = CloudNotificationCorrelation.key(machineID: provider.machine.rawValue, notificationID: row.id)
        SupermuxComposition.deviceNotificationProjects.remember(
            provider.notificationFeed.supermuxProjects[row.id],
            forCorrelationKey: key
        )
        let outcome = provider.deliverNotification(row, to: target)
        SupermuxComposition.deviceNotificationRetry.noteOutcome(outcome, for: provider)
        return outcome
    }
}

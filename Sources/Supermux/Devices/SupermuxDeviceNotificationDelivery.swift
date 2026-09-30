import CmuxCloud
import Foundation

/// Wraps upstream's delivery of another Mac's notification onto a local mirror
/// pane (`DeviceSurfaceProvider.deliverNotification`) with three parity rules,
/// through the `device-notification-parity` touchpoint:
///
/// 1. **Remote project.** The row's project from the other Mac's feed is
///    remembered under the record's correlation key, so the banner and the
///    local feed show that Mac's project.
/// 2. **Seen on arrival = read on the host.** A record the store created
///    already read (the mirror pane was on screen for someone at this Mac)
///    reports `.suppressed`, so the sync sends `notification.feed.mark_read`
///    to the host, the same acknowledgement a later local read would send.
/// 3. **Rate-limited rows retry soon.** A declined row (over the admission
///    budget) schedules a short retry instead of waiting for the next feed
///    event (``SupermuxDeviceNotificationRetry``).
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
        let outcome = acknowledgingSeenArrival(
            provider.deliverNotification(row, to: target),
            correlationKey: key,
            store: AppDelegate.shared?.notificationStore
        )
        SupermuxComposition.deviceNotificationRetry.noteOutcome(outcome, for: provider)
        return outcome
    }

    /// `.delivered` becomes `.suppressed` when the local record was created
    /// already read. Remote-origin records run no notification hooks, so the
    /// store records them synchronously and the lookup sees the new record.
    static func acknowledgingSeenArrival(
        _ outcome: CloudNotificationDeliveryOutcome,
        correlationKey: String,
        store: TerminalNotificationStore?
    ) -> CloudNotificationDeliveryOutcome {
        guard outcome == .delivered,
              let record = store?.notifications.first(where: { $0.correlationKey == correlationKey }),
              record.isRead else { return outcome }
        #if DEBUG
        cmuxDebugLog("supermux.device.notification.seenOnArrival workspace=\(record.tabId.uuidString.prefix(8)) → ack host")
        #endif
        return .suppressed
    }
}

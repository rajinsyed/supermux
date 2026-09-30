import Foundation
import SupermuxKit

/// App-wide instances for notification and phone-push parity across the
/// user's Macs (workstream Mb), behind the fork's single sanctioned global.
@MainActor
extension SupermuxComposition {
    /// Remote project per mirrored notification (correlation key → project).
    static let deviceNotificationProjects = SupermuxDeviceNotificationProjects()

    /// Short-timer retry of rate-limited device notification rows.
    static let deviceNotificationRetry = SupermuxDeviceNotificationRetry()

    /// Shares direct-APNs credentials and phone registrations with other Macs.
    static let phonePushShareCoordinator = SupermuxPhonePushShareCoordinator(
        devices: devices,
        service: phonePushService,
        settings: devicesSettings
    )
}

/// Launch-time activation, called from ``SupermuxDevicesGlue/activateIfNeeded()``.
@MainActor
enum SupermuxDeviceNotificationsGlue {
    /// Starts the push-share coordinator. Later calls are no-ops.
    static func activateIfNeeded() {
        SupermuxComposition.phonePushShareCoordinator.start()
    }
}

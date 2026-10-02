import Foundation
import SupermuxKit

/// App-wide instances for forwarding other Macs' ports to this Mac. Built
/// once, on first use.
@MainActor
extension SupermuxComposition {
    /// Other Macs' ports forwarded to `localhost` here.
    static let portForwards = SupermuxPortForwards(
        devices: devices,
        index: deviceWorkspaceIndex,
        settings: devicesSettings
    )
}

/// Launch-time activation of port forwarding, called from
/// ``SupermuxDevicesGlue/activateIfNeeded()``.
@MainActor
enum SupermuxPortsGlue {
    /// Starts following other Macs' ports. Idempotent.
    static func activateIfNeeded() {
        SupermuxComposition.portForwards.start()
    }
}

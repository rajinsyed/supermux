import Foundation
import SupermuxKit

/// App-wide instances for device mirrors: auto-mirror, close semantics, the
/// hidden set and status projection. Built once, on first use.
@MainActor
extension SupermuxComposition {
    /// Remote workspaces the user chose to "Hide Here".
    static let hiddenRemoteWorkspaces = SupermuxHiddenRemoteWorkspaces(defaults: .standard)

    /// Remote record -> mirror row status (activity/branch/PR overlays, pills, progress, log).
    static let deviceStatusProjector = SupermuxDeviceStatusProjector(
        devices: devices,
        index: deviceWorkspaceIndex
    )

    /// Close on <Mac> / Hide Here / programmatic and coordinator closes.
    static let deviceMirrorCloser = SupermuxDeviceMirrorCloser(
        devices: devices,
        index: deviceWorkspaceIndex,
        hidden: hiddenRemoteWorkspaces
    )

    /// The auto-mirror reconcile loop.
    static let deviceMirrorCoordinator: SupermuxDeviceMirrorCoordinator = {
        let coordinator = SupermuxDeviceMirrorCoordinator(
            devices: devices,
            index: deviceWorkspaceIndex,
            opener: deviceWorkspaceOpener,
            hidden: hiddenRemoteWorkspaces,
            settings: devicesSettings,
            closer: deviceMirrorCloser,
            projector: deviceStatusProjector
        )
        deviceMirrorCloser.onChange = { [weak coordinator] in coordinator?.scheduleReconcile() }
        return coordinator
    }()
}

/// Launch-time activation of the device-mirror services, called from
/// ``SupermuxDevicesGlue/activateIfNeeded()``.
@MainActor
enum SupermuxDeviceMirrorsGlue {
    /// Starts the auto-mirror coordinator. Idempotent.
    static func activateIfNeeded() {
        SupermuxComposition.deviceMirrorCoordinator.start()
    }

    /// Unhides remote workspaces (every device's when `machineID` is nil, or
    /// one ref) and lets auto-mirror reopen them.
    @discardableResult
    static func unhide(machineID: String? = nil, ref: SupermuxRemoteWorkspaceRef? = nil) -> [SupermuxRemoteWorkspaceRef] {
        let hidden = SupermuxComposition.hiddenRemoteWorkspaces
        let removed: [SupermuxRemoteWorkspaceRef]
        if let ref {
            removed = hidden.unhide(ref) ? [ref] : []
        } else {
            removed = hidden.unhide(machineID: machineID)
        }
        if !removed.isEmpty { SupermuxComposition.deviceMirrorCoordinator.scheduleReconcile() }
        return removed
    }
}

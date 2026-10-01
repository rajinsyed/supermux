import Foundation
import SupermuxKit

/// App-wide instances for device mirrors: auto-mirror, close semantics, the
/// hidden set and status projection. Built once, on first use.
@MainActor
extension SupermuxComposition {
    /// Remote workspaces the user chose to "Hide Here".
    static let hiddenRemoteWorkspaces = SupermuxHiddenRemoteWorkspaces(defaults: .standard)

    /// Remote workspaces closed here while their Mac was offline (or whose
    /// close is in flight): auto-mirror never reopens them, and the close is
    /// sent once that Mac is back. Never the Hide Here set.
    static let pendingRemoteWorkspaceCloses = SupermuxHiddenRemoteWorkspaces(
        defaults: .standard,
        key: "supermux.devices.pendingRemoteCloses.v1"
    )

    /// Remote record -> mirror row status (activity/branch/PR overlays, pills, progress, log).
    static let deviceStatusProjector = SupermuxDeviceStatusProjector(
        devices: devices,
        index: deviceWorkspaceIndex
    )

    /// User closes (on the mirror's Mac) / Hide Here / programmatic and coordinator closes.
    static let deviceMirrorCloser = SupermuxDeviceMirrorCloser(
        devices: devices,
        index: deviceWorkspaceIndex,
        hidden: hiddenRemoteWorkspaces,
        pending: pendingRemoteWorkspaceCloses
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

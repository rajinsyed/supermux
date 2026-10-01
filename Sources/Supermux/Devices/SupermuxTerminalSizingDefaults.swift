import CmuxCloud
import CmuxSurfaceCatalogModel
import CmuxTerminalSharing
import Foundation

/// This Mac's terminal size preference.
@MainActor
final class SupermuxTerminalSizingDefaults {
    // MARK: - Viewer identity

    /// This Mac's sizing identity as a viewer of `instance`'s terminals.
    ///
    /// DEBUG: the loopback device's host is this very app, so its mirrors
    /// would share the source pane's priority key. They get a distinct
    /// device id instead, as a second real Mac has. Release builds always
    /// use this Mac's own identity.
    static func viewerIdentity(for instance: SurfaceDeviceInstanceID) -> TerminalSharingIdentity {
        var identity = TerminalController.shared.localSizingIdentity()
        #if DEBUG
        if instance.deviceID == SupermuxDeviceLoopbackIdentity.deviceID {
            identity.deviceID = TerminalSharingIdentity.sizingDeviceID(
                installID: "loopback-viewer:" + MobileHostIdentity.deviceID()
            )
        }
        #endif
        return identity
    }
}

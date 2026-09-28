import Foundation

/// App-wide instances for the fork's device-mirror behaviors (⌘G, presets,
/// Changes, Files hint, New Workspace on ▸ <Mac>), behind the single
/// sanctioned composition global; each is built once with its dependencies.
@MainActor
extension SupermuxComposition {
    /// Local workspace -> the remote workspace it mirrors.
    static let mirrorResolver = SupermuxMirrorResolver(devices: devices, index: deviceWorkspaceIndex)

    /// Each owning Mac's projects, presets and run state, as mirrors need them.
    static let mirrorRemoteState = SupermuxMirrorRemoteState(devices: devices)

    /// ⌘G / Run inside a mirror runs on the owning Mac.
    static let mirrorRuns = SupermuxMirrorRunController(
        resolver: mirrorResolver,
        remoteState: mirrorRemoteState,
        devices: devices
    )

    /// Presets-bar chips inside a mirror launch on the owning Mac.
    static let mirrorPresets = SupermuxMirrorPresetLauncher(remoteState: mirrorRemoteState, devices: devices)

    /// Remote project actions (`action.run`).
    static var mirrorProjectActions: SupermuxMirrorProjectActions {
        SupermuxMirrorProjectActions(devices: devices)
    }

    /// Mounted Changes panels' mirror sources (socket introspection).
    static let mirrorChangesPanels = SupermuxMirrorChangesPanels()

    /// "New Workspace on ▸ <Mac>" and ⌘N on a device-backed workspace.
    static let deviceNewWorkspace = SupermuxDeviceNewWorkspaceAction(
        devices: devices,
        opener: deviceWorkspaceOpener
    )

    /// The AppKit target of the "New Workspace on ▸ <Mac>" rows.
    static let newWorkspaceDeviceMenuTarget = SupermuxNewWorkspaceDeviceMenuTarget()
}

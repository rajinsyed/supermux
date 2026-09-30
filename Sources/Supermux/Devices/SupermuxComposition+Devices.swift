import Foundation
import Observation
import SupermuxKit

/// App-wide instances for remote Macs ("devices"), behind the fork's single
/// sanctioned global (see ``SupermuxComposition``). Each is built once, on
/// first use, with its dependencies injected.
@MainActor
extension SupermuxComposition {
    /// The device facade: list, link state, records, RPC, capabilities, events.
    static let devices: SupermuxDevices = {
        let devices = SupermuxDevices(catalog: .shared)
        devices.start()
        return devices
    }()

    /// Persisted local mirror <-> remote workspace bindings (this app's defaults domain).
    static let deviceBindings = SupermuxDeviceBindingStore(defaults: .standard)

    /// Local workspace <-> remote workspace mapping across every window.
    static let deviceWorkspaceIndex = SupermuxDeviceWorkspaceIndex(
        catalog: .shared,
        devices: devices,
        bindings: deviceBindings
    )

    /// The one shared open / create / await path for device mirrors.
    static let deviceWorkspaceOpener = SupermuxDeviceWorkspaceOpener(
        catalog: .shared,
        devices: devices,
        index: deviceWorkspaceIndex
    )

    /// Fork device preferences (`supermux.devices.autoMirror`).
    static let devicesSettings = SupermuxDevicesSettings(defaults: .standard)

    /// Cached `origin` URL lookups, shared by the host's `projects.list`
    /// payload and the local Mac UI.
    static let gitRemoteResolver = SupermuxGitRemoteURLResolver()

    /// Each local project's `origin` URL, observable (kept current by
    /// ``SupermuxDevicesGlue``).
    static let projectGitRemotes = SupermuxProjectGitRemotes(resolver: gitRemoteResolver)
}

/// Launch-time activation for the device foundation, called from
/// ``SupermuxMobileHostGlue/activateIfNeeded()`` (itself reached from the
/// existing `mobile-supermux-observers` touchpoint), so no new upstream hook.
@MainActor
enum SupermuxDevicesGlue {
    private static var projectRemotesTask: Task<Void, Never>?

    /// Starts the device facade and keeps ``SupermuxComposition/projectGitRemotes``
    /// in step with the projects list. Later calls are no-ops.
    static func activateIfNeeded() {
        guard projectRemotesTask == nil else { return }
        _ = SupermuxComposition.devices
        SupermuxDeviceNotificationsGlue.activateIfNeeded()
        projectRemotesTask = Task { @MainActor in
            let model = SupermuxComposition.projectsModel
            await model.loadIfNeeded()
            while !Task.isCancelled {
                await SupermuxComposition.projectGitRemotes.refresh(projects: model.projects)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = model.projects
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

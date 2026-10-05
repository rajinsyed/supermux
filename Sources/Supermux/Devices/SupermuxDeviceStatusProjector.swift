import CMUXMobileCore
import CmuxSidebar
import Foundation
import SupermuxKit

/// Projects each mirror's remote `WorkspaceSyncRecord` onto its local mirror
/// `Workspace`, so a mirror row shows what the owning Mac's row shows.
///
/// - **Overlays** (read, never written into the workspace): agent activity
///   (the row's, and each tab's via `workingPanelIDs`), branch and PR.
///   ``SupermuxWorkspaceActivityResolver/activity(for:)``,
///   `Workspace.supermuxSidebarBranch` and ``SupermuxWorkspaceRow`` consult
///   ``status(forLocal:)`` first. Activity is deliberately NOT written as an
///   agent lifecycle into the mirror panes: an `.idle` lifecycle would make the
///   mirror eligible for agent hibernation.
/// - **Written into the mirror**: the remote `cmux set-status` pills (under
///   ``remoteStatusKeyPrefix`` so they never collide with local keys), the
///   progress bar, the latest log line (source ``remoteLogSource``), and the
///   remote's custom color, description and pin (remote → local, applied when
///   the remote value changes).
///
/// Every consumer refreshes: pills/progress/log/color/description/pin ride the
/// workspace's own sidebar publishers; activity/branch/PR changes fire
/// ``SupermuxWorkspaceLifecycleRelay`` (nested project rows observe it, the flat
/// list via the `device-mirror-flatrow-refresh` touchpoint).
///
/// A live workspace that stops being a mirror (an unbound mirror that got a
/// local pane) loses the remote pills, log line and projected progress, so
/// they neither linger on it nor get exported as its own.
@MainActor
final class SupermuxDeviceStatusProjector {
    /// Status keys of remote pills on a mirror start with this.
    static let remoteStatusKeyPrefix = "supermux.remote."
    /// `SidebarLogEntry.source` of the remote's latest log line on a mirror.
    static let remoteLogSource = "supermux-remote"

    private let devices: SupermuxDevices
    private let index: SupermuxDeviceWorkspaceIndex
    private var statusByWorkspaceID: [UUID: SupermuxDeviceMirrorStatus] = [:]
    /// What the last pass read, so a pass with nothing new does nothing.
    private var lastInputs: Inputs?

    init(devices: SupermuxDevices, index: SupermuxDeviceWorkspaceIndex) {
        self.devices = devices
        self.index = index
    }

    /// The remote status of a local mirror, or nil for a local workspace.
    func status(forLocal workspaceID: UUID) -> SupermuxDeviceMirrorStatus? {
        statusByWorkspaceID[workspaceID]
    }

    /// Re-reads every mirror's record and applies what changed. Does nothing
    /// unless `force` or a mirror, a device's link, records or projected tabs
    /// changed since the last pass.
    func refresh(force: Bool = false) {
        let current = index.mirrors()
        let inputs = Inputs(mirrors: current, devices: devices)
        guard force || inputs != lastInputs else { return }
        lastInputs = inputs
        var next: [UUID: SupermuxDeviceMirrorStatus] = [:]
        var overlayChanged: [UUID] = []
        var mirrors: [Workspace] = []
        for mirror in current {
            let workspace = mirror.workspace
            let previous = statusByWorkspaceID[workspace.id]
            let status: SupermuxDeviceMirrorStatus
            if let record = devices.record(for: mirror.ref) {
                let isConnected = devices.device(for: mirror.ref.machine)?.isConnected ?? false
                status = SupermuxDeviceMirrorStatus(record: record, isConnected: isConnected)
                if status != previous {
                    // After a relaunch `previous` is nil: the persisted baseline
                    // keeps a restored mirror's local color/description/pin edits.
                    let baseline = previous?.customization ?? index.appliedCustomization(for: workspace)
                    SupermuxDeviceMirrorStatusWriter(workspace: workspace)
                        .apply(status, previous: previous, customizationBaseline: baseline)
                    index.recordAppliedCustomization(status.customization, for: workspace)
                }
            } else if var kept = previous {
                // Record gone (device offline or workspace closing): keep what
                // the row showed, minus live activity.
                kept.activity = .idle
                kept.workingPanelIDs = []
                status = kept
            } else {
                continue
            }
            next[workspace.id] = status
            mirrors.append(workspace)
            if Self.overlayDiffers(previous, status) { overlayChanged.append(workspace.id) }
        }
        for (id, projected) in statusByWorkspaceID where next[id] == nil {
            guard let workspace = Workspace.liveWorkspace(id: id), !index.isDeviceMirror(workspace) else { continue }
            SupermuxDeviceMirrorStatusWriter(workspace: workspace).clear(projected)
            overlayChanged.append(id)
        }
        statusByWorkspaceID = next
        // A mirror tab projected after its overlay arrived (a tab moved in
        // from another workspace, a mirror opened mid-turn) has no relay of its
        // own; the catalog change that projected it re-runs this pass.
        for workspace in mirrors { SupermuxTabActivitySync.shared.sync(workspace) }
        // After the store update, so every observer reads the new overlay.
        for id in overlayChanged {
            SupermuxWorkspaceLifecycleRelay.lifecycleDidChange.send(id)
        }
    }

    /// What one pass reads: which local workspace mirrors which remote one,
    /// and per device its link state, its records (by their stamp) and its
    /// projected tabs (a tab moved into a mirror re-syncs its spinner).
    private struct Inputs: Equatable {
        struct Device: Equatable {
            let device: SupermuxDevice
            let records: SupermuxDevices.RecordsStamp?
            let projectionVersion: UInt64
        }

        struct Mirror: Equatable {
            let ref: SupermuxRemoteWorkspaceRef
            let workspaceID: UUID
        }

        let devices: [Device]
        let mirrors: [Mirror]

        @MainActor
        init(mirrors: [SupermuxDeviceMirror], devices: SupermuxDevices) {
            self.devices = devices.devices.map { device in
                Device(
                    device: device,
                    records: devices.recordsStamp(on: device.machine),
                    projectionVersion: devices.catalog.projectionVersions[device.machine, default: 0]
                )
            }
            self.mirrors = mirrors.map { Mirror(ref: $0.ref, workspaceID: $0.workspace.id) }
        }
    }

    private static func overlayDiffers(_ previous: SupermuxDeviceMirrorStatus?, _ status: SupermuxDeviceMirrorStatus) -> Bool {
        previous?.activity != status.activity
            || previous?.workingPanelIDs != status.workingPanelIDs
            || previous?.branch != status.branch
            || previous?.pullRequest != status.pullRequest
    }
}

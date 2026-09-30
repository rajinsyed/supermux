import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxMobileCore

/// The Files panel root for a device mirror. When the owning Mac serves
/// `supermux.files_read.v1`, the panel browses that Mac's folder for the
/// workspace (its current directory, so it follows a `cd` there) through
/// ``SupermuxDeviceFileExplorerProvider``; it never reads this Mac's disk.
/// Every other state keeps upstream's unavailable root with a sentence that
/// names the Mac:
///
/// | State | Panel says |
/// |---|---|
/// | link down | "<Mac> is not connected right now." |
/// | capabilities not known yet | "Loading files from <Mac>…" (and asks for them) |
/// | an older Supermux there | "Update Supermux on <Mac> to browse its files here." |
/// | no folder reported yet | "<Mac> has not reported this workspace's folder yet." |
///
/// Used by the `mirror-file-explorer-hint` touchpoint in
/// `FileExplorerWorkspaceRootResolver.swift`; ``followDeviceChanges(for:)`` by
/// `mirror-file-explorer-follow` in `FileExplorerWorkspaceObservation.swift`.
@MainActor
enum SupermuxMirrorFileExplorerRoot {
    /// The mirror's root; `nil` for other workspaces.
    static func root(for workspace: Workspace) -> FileExplorerWorkspaceRoot? {
        guard let target = SupermuxComposition.mirrorResolver.target(for: workspace) else { return nil }
        let devices = SupermuxComposition.devices
        let name = target.deviceName
        guard target.isConnected else {
            return unavailable(workspace, target, detail: SupermuxDeviceError.notConnected(name).errorDescription)
        }
        guard let capabilities = devices.cachedHostCapabilities(on: target.machine) else {
            requestCapabilities(on: target.machine, devices: devices)
            return unavailable(workspace, target, detail: String(
                localized: "supermux.mirror.files.loading",
                defaultValue: "Loading files from \(name)…"
            ))
        }
        guard capabilities.contains(SupermuxMobileCapability.filesReadV1.rawValue) else {
            return unavailable(workspace, target, detail: String(
                localized: "supermux.mirror.files.updateMac",
                defaultValue: "Update Supermux on \(name) to browse its files here."
            ))
        }
        guard let directory = target.remoteDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            return unavailable(workspace, target, detail: String(
                localized: "supermux.mirror.files.noFolder",
                defaultValue: "\(name) has not reported this workspace's folder yet."
            ))
        }
        return .supermuxDevice(SupermuxMirrorFileRoot(
            workspaceID: workspace.id,
            machine: target.machine,
            remoteWorkspaceID: target.remoteWorkspaceID,
            deviceName: name,
            rootPath: directory
        ))
    }

    /// Re-resolves a mirror's Files root whenever the devices change (the
    /// remote folder after a `cd`, the link going down or up, capabilities
    /// arriving), the way upstream's observation follows a Cloud machine.
    /// Ends once the observation stops or goes away.
    static func followDeviceChanges(for observation: FileExplorerWorkspaceObservation) {
        guard let workspace = observation.workspace,
              SupermuxComposition.deviceWorkspaceIndex.isDeviceMirror(workspace) else { return }
        let devices = SupermuxComposition.devices
        Task { @MainActor [weak observation] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = devices.revision
                    } onChange: {
                        continuation.resume()
                    }
                }
                // onChange fires at willSet: let the bump land first.
                await Task.yield()
                guard let observation, observation.workspace != nil else { return }
                observation.refresh()
            }
        }
    }

    private static func unavailable(
        _ workspace: Workspace,
        _ target: SupermuxMirrorTarget,
        detail: String?
    ) -> FileExplorerWorkspaceRoot {
        .remoteCloud(
            workspaceId: workspace.id,
            vmID: "",
            displayTarget: target.deviceName,
            rootPath: nil,
            isAvailable: false,
            unavailableDetail: detail,
            target: nil
        )
    }

    /// Fetches the Mac's capabilities once per link connection, then makes
    /// every mirror re-resolve (a failed fetch waits for the next change).
    private static func requestCapabilities(on machine: SurfaceMachineID, devices: SupermuxDevices) {
        Task { @MainActor in
            guard await devices.hostCapabilities(on: machine) != nil else { return }
            devices.scheduleRefresh()
        }
    }
}

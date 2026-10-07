import CMUXMobileCore
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// What a local mirror row shows about its remote workspace, read from the
/// device's synced `WorkspaceSyncRecord`: agent activity, branch, the
/// remote `cmux set-status` pills, progress and latest log, and the remote's
/// custom color, description and pin.
///
/// Built by ``SupermuxDeviceStatusProjector`` for every mirror; the overlays in
/// ``SupermuxWorkspaceActivityResolver`` and `Workspace.supermuxSidebarBranch`
/// read it, and the projector writes the pills,
/// progress and log into the mirror `Workspace` itself.
struct SupermuxDeviceMirrorStatus: Equatable {
    var activity: SupermuxWorkspaceActivity = .idle
    /// The other Mac's terminals (upper-cased ids) whose own agent is working,
    /// for the mirror's per-tab spinners; nil from a Mac that predates the
    /// field or while the device is offline.
    var workingPanelIDs: Set<String>?
    var branch: String?
    var statusEntries: [WorkspaceSyncRecord.SupermuxStatusEntry] = []
    var progress: WorkspaceSyncRecord.SupermuxProgress?
    var log: WorkspaceSyncRecord.SupermuxLog?
    var customization = SupermuxMirrorCustomization(colorHex: nil, description: nil, isPinned: false)

    /// The status the record reports. An offline device reports no live
    /// activity (a stale spinner would claim work nobody can see); everything
    /// else keeps its last synced value.
    init(record: WorkspaceSyncRecord, isConnected: Bool) {
        if isConnected {
            activity = Self.activity(fromWire: record.supermuxActivity)
            workingPanelIDs = record.supermuxWorkingPanelIDs.map { Set($0.map { $0.uppercased() }) }
        }
        branch = record.supermuxBranch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        statusEntries = record.supermuxStatusEntries ?? []
        progress = record.supermuxProgress
        log = record.supermuxLog
        customization = SupermuxMirrorCustomization(
            colorHex: record.customColorHex,
            description: record.customDescription,
            isPinned: record.isPinned
        )
    }

    /// Maps the `supermux_activity` wire value (`working` / `needs_input` /
    /// `ready`; absent means idle).
    static func activity(fromWire raw: String?) -> SupermuxWorkspaceActivity {
        switch raw.flatMap(SupermuxWorkspaceActivityDTO.init(rawValue:)) {
        case .working: .working
        case .needsInput: .needsInput
        case .ready: .ready
        case nil: .idle
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

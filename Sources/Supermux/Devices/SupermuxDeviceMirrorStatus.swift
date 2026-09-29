import CMUXMobileCore
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// What a local mirror row shows about its remote workspace, read from the
/// device's synced `WorkspaceSyncRecord`: agent activity, branch and PR, the
/// remote `cmux set-status` pills, progress and latest log, and the remote's
/// custom color, description and pin.
///
/// Built by ``SupermuxDeviceStatusProjector`` for every mirror; the overlays in
/// ``SupermuxWorkspaceActivityResolver``, `Workspace.supermuxSidebarBranch` and
/// ``SupermuxWorkspaceRow`` read it, and the projector writes the pills,
/// progress and log into the mirror `Workspace` itself.
struct SupermuxDeviceMirrorStatus: Equatable {
    var activity: SupermuxWorkspaceActivity = .idle
    var branch: String?
    var pullRequest: SupermuxPullRequest?
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
        }
        branch = record.supermuxBranch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        pullRequest = Self.pullRequest(from: record.supermuxPullRequest)
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

    /// The badge value for the record's `supermux_pull_request`, or nil when
    /// it is missing a number, a known state or a URL.
    static func pullRequest(from wire: WorkspaceSyncRecord.SupermuxPullRequest?) -> SupermuxPullRequest? {
        guard let wire,
              let number = wire.number,
              let status = wire.state.flatMap({ SupermuxPullRequest.Status(rawValue: $0.lowercased()) }),
              let url = wire.url.flatMap(URL.init(string:)) else { return nil }
        return SupermuxPullRequest(number: number, status: status, url: url, isStale: wire.isStale ?? false)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

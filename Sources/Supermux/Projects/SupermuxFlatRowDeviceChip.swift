import SupermuxKit
import SwiftUI

/// The Mac icon on a flat sidebar row that mirrors another Mac's workspace
/// (the `sidebar-flatrow-device-chip` touchpoint in `TabItemView`): the small
/// ``SupermuxRemoteMacIcon`` with the Mac's name in its tooltip, as the first
/// thing on the row's branch/directory line, or before the title when the row
/// shows no such line (``drawsOnBranchLine(_:settings:)``). Unlike upstream's
/// icon-only badge it shows whatever the branch/directory detail setting.
/// The Mac name comes from the row snapshot's existing `deviceWorkspaceLabel`;
/// the icon looks that Mac's link up in the device facade and dims while it is
/// offline or connecting. Only this small view observes the facade, so a link
/// change re-renders the icon, not the row. (The type keeps its old "chip"
/// name, which the touchpoint and its callers use.)
struct SupermuxFlatRowDeviceChip: View {
    let deviceWorkspaceLabel: String
    /// The glyph's point size: the neighboring branch glyph's or badge's.
    let pointSize: CGFloat
    /// The row's secondary color, so the icon follows a selected row.
    let tint: Color

    var body: some View {
        let name = Self.macName(fromDeviceWorkspaceLabel: deviceWorkspaceLabel)
        SupermuxRemoteMacIcon(
            name: name,
            state: Self.state(ofMacNamed: name, devices: SupermuxComposition.devices.devices),
            pointSize: pointSize,
            tint: tint
        )
    }

    /// Whether `TabItemView` draws a branch/directory line for this snapshot,
    /// so the icon goes there; otherwise it goes before the title. Mirrors the
    /// row's own branch-line conditions (detail visible, then per layout).
    static func drawsOnBranchLine(
        _ snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        settings: SidebarTabItemSettingsSnapshot
    ) -> Bool {
        guard settings.visibleAuxiliaryDetails.showsBranchDirectory else { return false }
        if settings.branchDirectory.branchLayout == .vertical {
            return !snapshot.branchDirectoryLines.isEmpty
        }
        if settings.branchDirectory.branchDirectoryPlacement == .stacked,
           snapshot.compactGitBranchSummaryText != nil || !snapshot.compactDirectoryCandidates.isEmpty {
            return true
        }
        return !snapshot.compactBranchDirectoryCandidates.isEmpty
    }

    /// The chip state of the Mac a flat row names.
    static func state(ofMacNamed name: String, devices: [SupermuxDevice]) -> SupermuxDeviceChipState {
        SupermuxDeviceChipState.resolve(name: name, among: devices.map { device in
            SupermuxDeviceChipState.Candidate(
                name: device.displayName,
                machineID: device.machine.rawValue,
                state: chipState(device.linkState)
            )
        })
    }

    private static func chipState(_ link: SupermuxDeviceLinkState) -> SupermuxDeviceChipState {
        switch link {
        case .connected: return .online
        case .connecting: return .connecting
        case .offline: return .offline
        }
    }

    /// The Mac name inside upstream's "Workspace on %@" label, recovered with
    /// the same localized format that built it; the whole label otherwise.
    static func macName(fromDeviceWorkspaceLabel label: String) -> String {
        let format = String(localized: "sidebar.deviceWorkspace.label", defaultValue: "Workspace on %@")
        let parts = format.components(separatedBy: "%@")
        guard parts.count == 2,
              label.hasPrefix(parts[0]),
              label.hasSuffix(parts[1]),
              label.count > parts[0].count + parts[1].count else { return label }
        let name = label.dropFirst(parts[0].count).dropLast(parts[1].count)
        return String(name).trimmingCharacters(in: .whitespaces)
    }
}

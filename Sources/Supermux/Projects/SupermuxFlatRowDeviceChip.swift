import SupermuxKit
import SwiftUI

/// The device-name chip on a flat sidebar row that mirrors another Mac's
/// workspace (the `sidebar-flatrow-device-chip` touchpoint in `TabItemView`).
/// Shown always, unlike upstream's icon-only badge, which appears only with
/// the branch/directory detail. The Mac name comes from the row snapshot's
/// existing `deviceWorkspaceLabel`; the chip itself looks that Mac's link up
/// in the device facade and dims while it is offline or connecting. Only this
/// small view observes the facade, so a link change re-renders the chip, not
/// the row.
struct SupermuxFlatRowDeviceChip: View {
    let deviceWorkspaceLabel: String
    let fontScale: CGFloat

    var body: some View {
        let name = Self.macName(fromDeviceWorkspaceLabel: deviceWorkspaceLabel)
        SupermuxDeviceChip(
            name: name,
            state: Self.state(ofMacNamed: name, devices: SupermuxComposition.devices.devices),
            fontScale: fontScale
        )
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

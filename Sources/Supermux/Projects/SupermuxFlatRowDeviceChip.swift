import SupermuxKit
import SwiftUI

/// The device-name chip on a flat sidebar row that mirrors another Mac's
/// workspace (the `sidebar-flatrow-device-chip` touchpoint in `TabItemView`).
/// Shown always, unlike upstream's icon-only badge, which appears only with
/// the branch/directory detail. Built from the row snapshot's existing
/// `deviceWorkspaceLabel`, so the row reads no model.
struct SupermuxFlatRowDeviceChip: View {
    let deviceWorkspaceLabel: String
    let fontScale: CGFloat

    var body: some View {
        SupermuxDeviceChip(
            name: Self.macName(fromDeviceWorkspaceLabel: deviceWorkspaceLabel),
            isOnline: true,
            fontScale: fontScale
        )
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

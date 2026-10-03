import SupermuxKit
import SwiftUI

/// The two mirror-only items of a flat sidebar row's context menu (the
/// `device-mirror-row-menu` touchpoint in `TabItemView+WorkspaceContextMenu`):
/// **Hide Here** (keeps the workspace running on its Mac, removes it from this
/// sidebar; no prompt, "Show Hidden Remote Workspaces" brings it back) and
/// **Close on <Mac>…** (the row's own close, which asks the mirror close
/// prompt). The nested project rows offer the same two items.
struct SupermuxMirrorRowMenuItems: View {
    let workspaceId: UUID
    /// Upstream's "Workspace on <Mac>" label of the row.
    let deviceWorkspaceLabel: String
    /// The row's close action (asks the mirror close prompt).
    let close: () -> Void

    var body: some View {
        let name = SupermuxFlatRowDeviceChip.macName(fromDeviceWorkspaceLabel: deviceWorkspaceLabel)
        let state = SupermuxFlatRowDeviceChip.state(ofMacNamed: name, devices: SupermuxComposition.devices.devices)
        Button(String(localized: "supermux.devices.close.button.hideHere", defaultValue: "Hide Here")) {
            SupermuxComposition.deviceMirrorCloser.hideHere(workspaceID: workspaceId)
        }
        Button(
            String(
                format: String(localized: "supermux.devices.menu.closeOnMac", defaultValue: "Close on %@…"),
                locale: .current, name
            ),
            role: .destructive,
            action: close
        )
        .disabled(state != .online)
    }
}

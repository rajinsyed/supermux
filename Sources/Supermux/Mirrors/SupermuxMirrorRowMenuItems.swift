import SupermuxKit
import SwiftUI

/// The mirror-only items of a flat sidebar row's context menu (the
/// `device-mirror-row-menu` touchpoint in `TabItemView+WorkspaceContextMenu`):
/// **Hide Here** keeps the workspace running on its Mac and removes it from
/// this sidebar (no prompt; "Show Hidden Remote Workspaces" brings it back),
/// and **Ports on <Mac>** (``SupermuxMirrorPortsMenu``). Upstream's Close
/// Workspace item above them closes the workspace on its Mac, like a local
/// one. The nested project rows offer the same items.
struct SupermuxMirrorRowMenuItems: View {
    let workspaceId: UUID

    var body: some View {
        Button(String(localized: "supermux.devices.close.button.hideHere", defaultValue: "Hide Here")) {
            SupermuxComposition.deviceMirrorCloser.hideHere(workspaceID: workspaceId)
        }
        SupermuxMirrorPortsMenu(workspaceId: workspaceId)
    }
}

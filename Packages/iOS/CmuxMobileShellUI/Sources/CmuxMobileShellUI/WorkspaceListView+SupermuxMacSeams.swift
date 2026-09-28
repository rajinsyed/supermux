// SUPERMUX:begin supermux-mobile-mac-seams (per-Mac Projects driver inputs: every live Mac's seam + the Mac-local id resolver — see SUPERMUX-TOUCHPOINTS.md)
import CmuxMobileShell
import SupermuxMobileUI

extension WorkspaceListView {
    /// Maps a Mac-local workspace id (what Supermux RPCs answer with) to the
    /// owning Mac's row id in the aggregated list, which is scoped per Mac
    /// once two Macs are paired. `nil` while the row is not listed yet.
    ///
    /// A separate property rather than an inline closure: `WorkspaceListView`'s
    /// body is already at the type checker's limit.
    var supermuxResolveWorkspace: SupermuxWorkspaceResolver? {
        guard let store else { return nil }
        let resolve: SupermuxWorkspaceResolver = { remoteWorkspaceID, macDeviceID, instanceTag in
            store.workspaceID(
                matchingRemoteWorkspaceID: remoteWorkspaceID,
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )?.rawValue
        }
        return resolve
    }
}
// SUPERMUX:end supermux-mobile-mac-seams

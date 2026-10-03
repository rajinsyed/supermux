// SUPERMUX:begin supermux-mobile-workspace-mac-seam (fork workspace tools talk to the Mac that OWNS the workspace, not whichever Mac is foreground — see SUPERMUX-TOUCHPOINTS.md)
import CmuxMobileRPC
import CmuxMobileShell

extension WorkspaceDetailView {
    /// The Supermux seam of the Mac that owns this workspace. Opening another
    /// Mac's workspace switches the foreground asynchronously; resolving by
    /// the row's own Mac keeps the Changes/Files tools, the title-menu
    /// entries and the pane actions on the right Mac before (and without)
    /// that switch. `nil` when the owning Mac has no live connection.
    var supermuxWorkspaceSeam: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)? {
        store.supermuxConnectionSeam(
            forMacDeviceID: workspace.macDeviceID,
            instanceTag: workspace.macInstanceTag
        )
    }
}
// SUPERMUX:end supermux-mobile-workspace-mac-seam

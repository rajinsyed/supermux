import Foundation
import SupermuxKit

/// Per-panel agent activity: what one tab's working indicator shows
/// (``SupermuxTabActivitySync``), resolved by the same core as the workspace
/// rows so a tab and its row never disagree.
extension SupermuxWorkspaceActivityResolver {
    /// The agent activity of one panel (one tab) of `workspace`, from that
    /// panel's own lifecycle values. A device mirror's panes carry no lifecycle
    /// and report idle.
    @MainActor
    static func activity(forPanel panelID: UUID, in workspace: Workspace) -> SupermuxWorkspaceActivity {
        if SupermuxComposition.deviceStatusProjector.status(forLocal: workspace.id) != nil {
            return .idle
        }
        return activity(fromStatesByPanelId: [panelID: workspace.agentLifecycleStatesByPanelId[panelID] ?? [:]])
    }
}

import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// Per-panel agent activity: what one tab's working indicator shows
/// (``SupermuxTabActivitySync``), resolved by the same core as the workspace
/// rows so a tab and its row never disagree.
extension SupermuxWorkspaceActivityResolver {
    /// The agent activity of one panel (one tab) of `workspace`, from that
    /// panel's own lifecycle values.
    ///
    /// A device mirror's panes carry no lifecycle: a mirror tab is working
    /// when the other Mac lists the terminal it shows in the record's
    /// `supermux_working_panel_ids` (never, for a Mac that predates the field).
    @MainActor
    static func activity(forPanel panelID: UUID, in workspace: Workspace) -> SupermuxWorkspaceActivity {
        if let mirror = SupermuxComposition.deviceStatusProjector.status(forLocal: workspace.id) {
            guard let working = mirror.workingPanelIDs,
                  let projection = SurfaceCatalog.shared.projection(forPanel: panelID),
                  projection.resource.machine.isDevice else { return .idle }
            return working.contains(projection.resource.key.uppercased()) ? .working : .idle
        }
        return activity(fromStatesByPanelId: [panelID: workspace.agentLifecycleStatesByPanelId[panelID] ?? [:]])
    }
}

extension Workspace {
    /// The ids of the panels whose own agent is working, in tab order: the
    /// record's `supermux_working_panel_ids` another Mac's mirror reads.
    @MainActor
    func supermuxWorkingPanelIDs() -> [String] {
        orderedPanelIds.compactMap { panelID in
            guard panels[panelID] != nil else { return nil }
            let states = agentLifecycleStatesByPanelId[panelID] ?? [:]
            let activity = SupermuxWorkspaceActivityResolver.activity(fromStatesByPanelId: [panelID: states])
            return activity == .working ? panelID.uuidString : nil
        }
    }
}

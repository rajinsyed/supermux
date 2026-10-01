import Bonsplit
import Combine
import Foundation
import SupermuxKit

/// Shows which tabs are working: each terminal and Claude harness tab's
/// built-in Bonsplit spinner (`isLoading`, drawn in the tab's icon slot)
/// follows its own panel's agent activity — on while that agent is running or
/// waiting on its background work, off otherwise.
///
/// Only terminal and Claude harness tabs are touched; nothing upstream writes
/// `isLoading` for either. A browser tab's spinner is its page load and a
/// Cloud VM placeholder's is its boot, both owned by upstream.
///
/// Driven by ``SupermuxWorkspaceLifecycleRelay``, which fires on every agent
/// lifecycle change and on every change of a device mirror's overlay; each
/// ``SupermuxDeviceStatusProjector`` pass also syncs every mirror, so a mirror
/// tab projected after its overlay arrived spins at once. The
/// changed workspaces are synced together on the next main-actor turn (after
/// the mutation that fired the relay has finished), walking each one's panels
/// once; Bonsplit's `updateTab` writes only a value that changed. A tab that
/// upstream rebuilds (respawn, session restore) gets its spinner back on the
/// next lifecycle event. Dock tabs are synced per panel from the
/// `dock-tab-agent-working` touchpoint (``syncDock(_:panelId:)``).
@MainActor
final class SupermuxTabActivitySync {
    static let shared = SupermuxTabActivitySync()

    private var cancellable: AnyCancellable?
    private var pendingWorkspaceIDs: Set<UUID> = []

    /// Starts following the relay; later calls do nothing.
    func start() {
        guard cancellable == nil else { return }
        cancellable = SupermuxWorkspaceLifecycleRelay.lifecycleDidChange.sink { [weak self] workspaceID in
            self?.schedule(workspaceID)
        }
    }

    private func schedule(_ workspaceID: UUID) {
        let isFirst = pendingWorkspaceIDs.isEmpty
        pendingWorkspaceIDs.insert(workspaceID)
        guard isFirst else { return }
        Task { [weak self] in self?.flush() }
    }

    private func flush() {
        let workspaceIDs = pendingWorkspaceIDs
        pendingWorkspaceIDs = []
        for workspaceID in workspaceIDs {
            guard let workspace = Workspace.liveWorkspace(id: workspaceID) else { continue }
            sync(workspace)
        }
    }

    /// Sets every terminal and Claude harness tab of `workspace` to its
    /// panel's working state.
    func sync(_ workspace: Workspace) {
        for (panelID, panel) in workspace.panels where panel.panelType == .terminal || panel.panelType == .claudeHarness {
            guard let tab = workspace.surfaceIdFromPanelId(panelID) else { continue }
            let activity = SupermuxWorkspaceActivityResolver.activity(forPanel: panelID, in: workspace)
            Self.setWorking(activity == .working, tab: tab, in: workspace.bonsplitController)
        }
    }

    /// Sets a Dock terminal tab to its panel's working state (the Dock keeps
    /// its own agent lifecycle per panel and never fires the relay). Claude
    /// harness panels never enter the Dock.
    static func syncDock(_ store: DockSplitStore, panelId: UUID) {
        guard store.panels[panelId]?.panelType == .terminal,
              let tab = store.surfaceId(forPanelId: panelId) else { return }
        let states = store.agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:]
        let activity = SupermuxWorkspaceActivityResolver.activity(fromStatesByPanelId: [panelId: states])
        setWorking(activity == .working, tab: tab, in: store.bonsplitController)
    }

    /// The one place a tab's working state is written. Bonsplit draws it as
    /// its own loading spinner in the tab's text colour; a fork tint (the
    /// sidebar's amber) would be applied here once Bonsplit can take one.
    static func setWorking(_ isWorking: Bool, tab: TabID, in controller: BonsplitController) {
        controller.updateTab(tab, isLoading: isWorking)
    }
}

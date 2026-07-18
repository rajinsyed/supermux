import Combine
import CmuxSidebar
import Foundation
import SupermuxKit

/// Derives a workspace's ``SupermuxWorkspaceActivity`` from cmux's per-agent
/// lifecycle state.
///
/// cmux tracks each agent's lifecycle (`running`/`needsInput`/`idle`) per panel
/// in `Workspace.agentLifecycleStatesByPanelId`. That store isn't `@Published`,
/// and several real paths mutate it without touching any field cmux's sidebar
/// publishers carry (the `set_agent_lifecycle` socket command, agent
/// hibernation's lifecycle clear, feed attention conclusion) — so a consumer
/// cannot rely on telemetry re-renders alone to read a current value here.
/// Every mutation is instead reported to ``SupermuxWorkspaceLifecycleRelay``
/// (the `workspace-agent-lifecycle-observation` touchpoint); re-render on that
/// relay — as ``SupermuxWorkspaceObservation`` does for the projects mount —
/// and resolve through this one shared resolver so every surface stays
/// consistent.
@MainActor
enum SupermuxWorkspaceActivityResolver {
    /// The most urgent agent activity across all of the workspace's panels.
    /// - Parameter workspace: The workspace to inspect.
    static func activity(for workspace: Workspace) -> SupermuxWorkspaceActivity {
        let lifecycleRawValues = workspace.agentLifecycleStatesByPanelId.values
            .flatMap { $0.values }
            .map(\.rawValue)
        return SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: lifecycleRawValues)
    }
}

/// Drops agent-published lifecycle status rows that duplicate the activity
/// indicator from a flat sidebar row's metadata.
///
/// Agent hooks report routine lifecycle twice: as a textual status row
/// (`set_status claude_code Running --icon=bolt.fill …` → the blue "⚡ Running"
/// line) and as the per-panel lifecycle state that drives
/// ``SupermuxAgentActivityIndicator``. Supermux renders the indicator on every
/// workspace row and the nested project-workspace rows never show the textual
/// row, so the flat (global) rows drop the duplicate too — one agent status
/// signal per row, identical styling in and out of projects.
///
/// A row is dropped only when it is *actually* a duplicate: its key is an agent
/// lifecycle key AND its icon shape matches the resolved indicator state
/// (`bolt.fill`↔working, `pause.circle.fill`↔ready, `bell.fill`↔needsInput).
/// Everything else keeps rendering — user-defined `set_status` rows, agent
/// error rows (`exclamationmark.triangle.fill`, e.g. "Codex network error"),
/// and status/lifecycle mismatches. Some hook paths publish only the status row
/// without a lifecycle update (codex transcript questions/failures), so a
/// key-only filter would silently erase the row's sole signal.
enum SupermuxSidebarAgentStatusRows {
    /// Returns `entries` without the agent status rows `activity` duplicates.
    static func droppingAgentStatusRows(
        from entries: [SidebarStatusEntry],
        duplicatedBy activity: SupermuxWorkspaceActivity
    ) -> [SidebarStatusEntry] {
        entries.filter { !isDuplicate($0, of: activity) }
    }

    private static func isDuplicate(
        _ entry: SidebarStatusEntry,
        of activity: SupermuxWorkspaceActivity
    ) -> Bool {
        guard AgentHibernationLifecycleStatusKeys.isAllowed(entry.key) else { return false }
        switch (entry.icon, activity) {
        case ("bolt.fill", .working),
             ("pause.circle.fill", .ready),
             ("bell.fill", .needsInput):
            return true
        default:
            return false
        }
    }
}

/// Broadcasts agent-lifecycle mutations that cmux itself never publishes.
///
/// `Workspace.recordAgentLifecycleChange` is the single choke point every
/// lifecycle set/clear already routes through; the fenced one-line touchpoint
/// there (`workspace-agent-lifecycle-observation` in `Workspace.swift`) reports
/// into this relay, turning the unpublished `agentLifecycleStatesByPanelId`
/// store into an observable stream without widening cmux's own sidebar
/// publishers. The relay is deliberately placed *before* the hibernation
/// controller's bookkeeping, which drops events while its tracking gate is
/// disabled.
@MainActor
enum SupermuxWorkspaceLifecycleRelay {
    /// Fires with the mutated workspace's id after any agent-lifecycle change.
    static let lifecycleDidChange = PassthroughSubject<UUID, Never>()

    /// Reports a lifecycle mutation on `workspace`. Called only from the fenced
    /// touchpoint in `Workspace.recordAgentLifecycleChange`.
    static func workspaceDidChangeAgentLifecycle(_ workspace: Workspace) {
        lifecycleDidChange.send(workspace.id)
    }
}

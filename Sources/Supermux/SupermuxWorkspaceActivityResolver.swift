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
        activity(fromStatesByPanelId: workspace.agentLifecycleStatesByPanelId)
    }

    /// Pure core of ``activity(for:)``, split out for unit testing.
    ///
    /// Reserved manual workspace-loading keys (`manual`/`manual:<id>`, written
    /// by `cmux workspace loading`) are excluded, mirroring upstream's own
    /// consumer (`Workspace.agentHibernationLifecycleState`): manual loaders
    /// drive cmux's gray sidebar spinner, never agent status.
    static func activity(
        fromStatesByPanelId statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> SupermuxWorkspaceActivity {
        let lifecycleRawValues = statesByPanelId.values.flatMap { states in
            states.compactMap { key, state in
                AgentHibernationLifecycleStatusKeys.isManualKey(key) ? nil : state.rawValue
            }
        }
        return SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: lifecycleRawValues)
    }

    /// Each agent key's own resolved activity across all of the workspace's
    /// panels. Keys with no lifecycle entry are absent. Manual workspace-loading
    /// keys are excluded, as in ``activity(for:)``.
    static func activityByAgentKey(for workspace: Workspace) -> [String: SupermuxWorkspaceActivity] {
        activityByAgentKey(fromStatesByPanelId: workspace.agentLifecycleStatesByPanelId)
    }

    /// Pure core of ``activityByAgentKey(for:)``, split out for unit testing.
    static func activityByAgentKey(
        fromStatesByPanelId statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> [String: SupermuxWorkspaceActivity] {
        var rawValuesByKey: [String: [String]] = [:]
        for states in statesByPanelId.values {
            for (key, state) in states where !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
                rawValuesByKey[key, default: []].append(state.rawValue)
            }
        }
        return rawValuesByKey.mapValues(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues:))
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
/// lifecycle key AND that key has its own tracked lifecycle AND its icon shape
/// matches that key's *own* resolved state (`bolt.fill`↔working,
/// `pause.circle.fill`↔ready, `bell.fill`↔needsInput) AND it carries no URL.
/// Matching per key — not against the workspace aggregate — matters in
/// multi-agent workspaces: agent A's lifecycle must never drop agent B's row.
/// Everything else keeps rendering — user-defined `set_status` rows, agent
/// error rows (`exclamationmark.triangle.fill`, e.g. "Codex network error"),
/// rows with click-through URLs, and status/lifecycle mismatches. Some hook
/// paths publish only the status row without a lifecycle update (codex
/// transcript questions/failures), so a key-only filter would silently erase
/// the row's sole signal. Known tradeoff: Claude Code's verbose tool status
/// ("Editing Foo.swift") shares the agent key and `bolt.fill` icon, so its text
/// is dropped while working — same as the nested project rows, which never show
/// textual status rows at all.
enum SupermuxSidebarAgentStatusRows {
    /// Returns `entries` without the agent status rows the per-key activities
    /// in `activityByAgentKey` duplicate.
    static func droppingAgentStatusRows(
        from entries: [SidebarStatusEntry],
        duplicatedBy activityByAgentKey: [String: SupermuxWorkspaceActivity]
    ) -> [SidebarStatusEntry] {
        entries.filter { !isDuplicate($0, of: activityByAgentKey) }
    }

    private static func isDuplicate(
        _ entry: SidebarStatusEntry,
        of activityByAgentKey: [String: SupermuxWorkspaceActivity]
    ) -> Bool {
        guard AgentHibernationLifecycleStatusKeys.isAllowed(entry.key),
              entry.url == nil,
              let ownActivity = activityByAgentKey[entry.key] else { return false }
        switch (entry.icon, ownActivity) {
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

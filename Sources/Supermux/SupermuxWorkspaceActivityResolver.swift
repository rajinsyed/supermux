import Combine
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

import SupermuxKit

/// Derives a workspace's ``SupermuxWorkspaceActivity`` from cmux's per-agent
/// lifecycle state.
///
/// cmux tracks each agent's lifecycle (`running`/`needsInput`/`idle`) per panel
/// in `Workspace.agentLifecycleStatesByPanelId`. That store isn't `@Published`,
/// but it changes in lockstep with the observable `statusEntries`/`progress`
/// the agent hooks also post — so any surface that re-renders on those (the
/// supermux projects mount, the sidebar snapshot builder, the agent tab) reads
/// a current value here. One shared resolver keeps every surface consistent.
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

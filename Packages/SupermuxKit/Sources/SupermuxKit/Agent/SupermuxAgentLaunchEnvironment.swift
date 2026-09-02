/// The three collaborators the "start Claude in a new worktree" UI needs,
/// bundled so hosts hand the projects section one optional value (and `nil`
/// hides every entry point).
@MainActor
public final class SupermuxAgentLaunchEnvironment {
    /// Names, creates, and describes the worktree launch.
    public let launcher: SupermuxAgentWorktreeLauncher
    /// Per-command model catalogs.
    public let catalog: SupermuxAgentModelCatalog
    /// Commands and remembered choices.
    public let settings: SupermuxAgentLauncherSettings

    /// Creates the bundle.
    public init(
        launcher: SupermuxAgentWorktreeLauncher,
        catalog: SupermuxAgentModelCatalog,
        settings: SupermuxAgentLauncherSettings
    ) {
        self.launcher = launcher
        self.catalog = catalog
        self.settings = settings
    }
}

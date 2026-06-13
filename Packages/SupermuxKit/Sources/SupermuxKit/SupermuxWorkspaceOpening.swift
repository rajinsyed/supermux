public import Foundation

/// What supermux asks the host app to open when the user activates a project
/// or worktree.
public struct SupermuxOpenWorkspaceRequest: Sendable, Hashable {
    /// Workspace title (project name or branch name).
    public var title: String
    /// Absolute working directory for the workspace.
    public var directory: String
    /// Accent color (`#RRGGBB`) applied to the workspace tab, if any.
    public var colorHex: String?
    /// A command to run in the workspace's first terminal, or `nil` for none.
    ///
    /// When set, the host always opens a fresh workspace (never reuses an
    /// existing one) so the command runs in a clean terminal — this is how
    /// custom project actions launch.
    public var initialCommand: String?
    /// The project this open originates from, when launched from a project row.
    ///
    /// The host records it so the resulting workspace nests under that project
    /// regardless of its directory. `nil` for opens not tied to a project, so
    /// those stay standalone in the flat list.
    public var projectId: UUID?

    /// Creates a request.
    /// - Parameters:
    ///   - title: Workspace title.
    ///   - directory: Absolute working directory.
    ///   - colorHex: Optional accent color.
    ///   - initialCommand: Optional command to run in the first terminal.
    ///   - projectId: Owning project to associate the opened workspace with.
    public init(
        title: String,
        directory: String,
        colorHex: String? = nil,
        initialCommand: String? = nil,
        projectId: UUID? = nil
    ) {
        self.title = title
        self.directory = directory
        self.colorHex = colorHex
        self.initialCommand = initialCommand
        self.projectId = projectId
    }
}

/// Seam through which SupermuxKit opens workspaces in the host app.
///
/// The cmux app target implements this with its `TabManager` (select an
/// existing workspace whose directory matches, otherwise create one). Keeping
/// the protocol here lets the whole projects UI live in this package without
/// depending on app-target types.
@MainActor
public protocol SupermuxWorkspaceOpening: AnyObject {
    /// Opens (or focuses) a workspace for the request.
    ///
    /// Used when *opening* a project or worktree — the result is a workspace.
    func openWorkspace(_ request: SupermuxOpenWorkspaceRequest)

    /// Runs the request's command as a new terminal tab in the currently
    /// focused workspace, rather than opening a separate workspace.
    ///
    /// Used by project *actions* (e.g. a build or agent command): the user
    /// expects them to run where they are looking, like the global presets bar,
    /// not to spawn a new workspace. Hosts should fall back to
    /// ``openWorkspace(_:)`` when there is no focused workspace to host the tab.
    func runAction(_ request: SupermuxOpenWorkspaceRequest)
}

public extension SupermuxWorkspaceOpening {
    /// Default behaviour: open a workspace, matching the legacy action path.
    /// Hosts that can target the focused workspace override this.
    func runAction(_ request: SupermuxOpenWorkspaceRequest) {
        openWorkspace(request)
    }
}

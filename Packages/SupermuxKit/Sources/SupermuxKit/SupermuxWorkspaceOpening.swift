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
    /// A setup script to run in a dedicated terminal of the newly created
    /// workspace, or `nil` for none.
    ///
    /// Used when opening a freshly created worktree: the host opens the
    /// workspace with a clean main terminal and additionally spawns one setup
    /// terminal that runs this script (with ``setupEnvironment`` exported). It
    /// runs in its own surface — not the main terminal — so a script ending in
    /// `exit` closes only the setup tab, never the workspace's primary shell.
    public var setupScript: String?
    /// Environment variables exported into the ``setupScript`` terminal (e.g.
    /// `SUPERSET_ROOT_PATH`). Empty when there is no setup script.
    public var setupEnvironment: [String: String]

    /// Whether the open must preserve the Mac user's current keyboard focus.
    ///
    /// `false` (default) is the desktop behavior: activating a project/worktree
    /// ON the Mac makes the new terminal the first responder. Remote (mobile)
    /// opens set `true` — per the cmux socket/focus policy, a command arriving
    /// from the phone must not yank keyboard focus out from under whatever the
    /// Mac user is doing. The workspace still opens and is selected (see
    /// ``selectsWorkspace``); only the terminal-surface first-responder grab
    /// is suppressed.
    public var preservesUserFocus: Bool

    /// Whether the opened (or reused) workspace becomes its window's selected
    /// workspace.
    ///
    /// `true` (default) for the desktop and the phone. `false` when another
    /// Mac asks: its user watches the workspace through a mirror there, so
    /// this Mac opens it in the background instead of switching the window
    /// under whoever is using it (its terminals still start).
    public var selectsWorkspace: Bool

    /// The pull request badge the worktree row was showing when the user opened
    /// it, or `nil` when it had none (or the open is not a worktree open).
    ///
    /// The host seeds it into its own per-workspace PR state so the nested
    /// workspace row keeps the badge from the first frame. Without it the
    /// unopened-worktree probe drops the path the moment it becomes an open
    /// workspace, and the row stays blank until cmux's own chain — shell
    /// directory report, git branch probe, PR poll, GitHub fetch — completes.
    /// cmux's probe remains authoritative: it confirms, updates, or clears the
    /// seeded badge on its first pass. No probe of any kind runs for the seed.
    public var pullRequest: SupermuxPullRequest?

    /// Creates a request.
    /// - Parameters:
    ///   - title: Workspace title.
    ///   - directory: Absolute working directory.
    ///   - colorHex: Optional accent color.
    ///   - initialCommand: Optional command to run in the first terminal.
    ///   - projectId: Owning project to associate the opened workspace with.
    ///   - setupScript: Setup script for a dedicated setup terminal, or `nil`.
    ///   - setupEnvironment: Variables exported into the setup terminal.
    ///   - preservesUserFocus: Suppress the keyboard-focus grab (remote opens).
    ///   - selectsWorkspace: Select the workspace (`false` when another Mac asks).
    ///   - pullRequest: The worktree row's current PR badge to hand off, if any.
    public init(
        title: String,
        directory: String,
        colorHex: String? = nil,
        initialCommand: String? = nil,
        projectId: UUID? = nil,
        setupScript: String? = nil,
        setupEnvironment: [String: String] = [:],
        preservesUserFocus: Bool = false,
        selectsWorkspace: Bool = true,
        pullRequest: SupermuxPullRequest? = nil
    ) {
        self.title = title
        self.directory = directory
        self.colorHex = colorHex
        self.initialCommand = initialCommand
        self.projectId = projectId
        self.setupScript = setupScript
        self.setupEnvironment = setupEnvironment
        self.preservesUserFocus = preservesUserFocus
        self.selectsWorkspace = selectsWorkspace
        self.pullRequest = pullRequest
    }

    /// The same request opened in the background: the window keeps its
    /// selected workspace and the user keeps keyboard focus. Used for a
    /// worktree created in the background, which must not pull the user out
    /// of whatever they moved on to.
    public var inBackground: SupermuxOpenWorkspaceRequest {
        var request = self
        request.selectsWorkspace = false
        request.preservesUserFocus = true
        return request
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
    ///
    /// Deliberately has no default implementation: with one, a host method
    /// whose signature drifted (e.g. gained a parameter) silently stopped
    /// witnessing this requirement, and every action opened a new workspace.
    func runAction(_ request: SupermuxOpenWorkspaceRequest)
}

public extension SupermuxWorkspaceOpening {
    /// Runs one of `project`'s actions where the user is looking
    /// (``runAction(_:)``): the path of a local project row's Actions menu.
    /// No-op for an action without a name or command.
    /// - Parameters:
    ///   - action: The action to run.
    ///   - project: The project that owns it.
    ///   - preservesUserFocus: Leave keyboard focus where it is instead of
    ///     moving it to the action's new tab.
    func runProjectAction(
        _ action: SupermuxProjectAction,
        of project: SupermuxProject,
        preservesUserFocus: Bool = false
    ) {
        guard action.isLaunchable else { return }
        runAction(.projectAction(action, of: project, preservesUserFocus: preservesUserFocus))
    }
}

public extension SupermuxOpenWorkspaceRequest {
    /// The request a project action runs with: its command, in a tab titled
    /// "<project> · <action>", associated with the project, at the project
    /// root when there is no workspace to run in.
    static func projectAction(
        _ action: SupermuxProjectAction,
        of project: SupermuxProject,
        preservesUserFocus: Bool = false
    ) -> SupermuxOpenWorkspaceRequest {
        SupermuxOpenWorkspaceRequest(
            title: "\(project.name) · \(action.name)",
            directory: project.rootPath,
            colorHex: project.colorHex,
            initialCommand: action.command,
            projectId: project.id,
            preservesUserFocus: preservesUserFocus
        )
    }
}

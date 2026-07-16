/// A `mobile.supermux.*` JSON-RPC method the supermux macOS host serves for
/// the iOS companion app.
///
/// The raw value is the exact wire string (architecture §2). The full set is
/// iterable via ``all`` so exhaustiveness tests (e.g. the authorization table)
/// can assert every method is classified.
public enum SupermuxMobileMethod: String, CaseIterable, Codable, Sendable, Equatable {
    // MARK: Projects

    /// Lists all registered projects.
    case projectsList = "mobile.supermux.projects.list"
    /// Registers a new project.
    case projectCreate = "mobile.supermux.project.create"
    /// Patches an existing project (only present keys applied).
    case projectUpdate = "mobile.supermux.project.update"
    /// Removes a project registration.
    case projectDelete = "mobile.supermux.project.delete"
    /// Opens a workspace at the project root on the Mac.
    case projectOpen = "mobile.supermux.project.open"
    /// Fetches the project's custom icon (base64 PNG, etag-cached).
    case projectIcon = "mobile.supermux.project.icon"
    /// Persists the sidebar Projects section's collapse state.
    case projectsSetSectionCollapsed = "mobile.supermux.projects.set_section_collapsed"

    // MARK: Worktrees

    /// Lists a project's worktrees (with PR data when available).
    case worktreesList = "mobile.supermux.worktrees.list"
    /// Suggests a branch name (AI when configured, random fallback).
    case worktreeSuggestBranch = "mobile.supermux.worktree.suggest_branch"
    /// Creates a new git worktree for a project.
    case worktreeCreate = "mobile.supermux.worktree.create"
    /// Opens a workspace in an existing worktree.
    case worktreeOpen = "mobile.supermux.worktree.open"
    /// Removes a worktree (dirty worktrees require `force`).
    case worktreeRemove = "mobile.supermux.worktree.remove"

    // MARK: Changes

    /// Starts/heartbeats/stops the per-workspace repository watcher.
    case changesWatch = "mobile.supermux.changes.watch"
    /// Reads the workspace repository's status snapshot.
    case changesStatus = "mobile.supermux.changes.status"
    /// Reads the diff for one file.
    case changesDiff = "mobile.supermux.changes.diff"
    /// Stages the given paths.
    case changesStage = "mobile.supermux.changes.stage"
    /// Unstages the given paths.
    case changesUnstage = "mobile.supermux.changes.unstage"
    /// Discards working-tree changes for the given paths.
    case changesDiscard = "mobile.supermux.changes.discard"
    /// Commits the staged changes.
    case changesCommit = "mobile.supermux.changes.commit"
    /// Generates a commit message mac-side (errors `ai_unavailable` without a key).
    case changesGenerateCommitMessage = "mobile.supermux.changes.generate_commit_message"
    /// Pushes to the upstream.
    case changesPush = "mobile.supermux.changes.push"
    /// Pulls from the upstream.
    case changesPull = "mobile.supermux.changes.pull"
    /// Stashes the working tree.
    case changesStash = "mobile.supermux.changes.stash"
    /// Pops the latest stash entry.
    case changesStashPop = "mobile.supermux.changes.stash_pop"
    /// Reads paginated commit history.
    case changesHistory = "mobile.supermux.changes.history"

    // MARK: Run

    /// Reads a project's run-action state.
    case runState = "mobile.supermux.run.state"
    /// Starts a project's run action.
    case runStart = "mobile.supermux.run.start"
    /// Stops a project's run action.
    case runStop = "mobile.supermux.run.stop"

    // MARK: Presets / actions

    /// Creates a terminal preset.
    case presetCreate = "mobile.supermux.preset.create"
    /// Patches a terminal preset.
    case presetUpdate = "mobile.supermux.preset.update"
    /// Deletes a terminal preset.
    case presetDelete = "mobile.supermux.preset.delete"
    /// Launches a preset in a new terminal on the Mac.
    case presetLaunch = "mobile.supermux.preset.launch"
    /// Runs a project action (`open_url` actions return the URL instead).
    case actionRun = "mobile.supermux.action.run"

    // MARK: Files

    /// Lists directory entries under the resolved root.
    case filesList = "mobile.supermux.files.list"
    /// Creates a file or folder.
    case filesCreate = "mobile.supermux.files.create"
    /// Renames a file or folder.
    case filesRename = "mobile.supermux.files.rename"
    /// Duplicates a file or folder.
    case filesDuplicate = "mobile.supermux.files.duplicate"
    /// Moves a file or folder to the Trash (never a permanent delete).
    case filesTrash = "mobile.supermux.files.trash"

    /// The shared method-name prefix; the Mac router dispatches on it.
    public static let namespacePrefix = "mobile.supermux."

    /// Every method, in declaration order (derived from `CaseIterable`).
    public static let all: [SupermuxMobileMethod] = SupermuxMobileMethod.allCases
}

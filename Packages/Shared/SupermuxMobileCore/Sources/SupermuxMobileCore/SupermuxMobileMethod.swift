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
    /// Reports whether a folder exists on the Mac as a git repo, and its
    /// origin (``SupermuxProjectProbeDTO``), so another Mac can register the
    /// same repository there without guessing (cross-Mac project sync).
    case projectProbe = "mobile.supermux.project.probe"
    /// `git clone`s a repository into a folder on the Mac and registers it as
    /// a project ("Set Up on <Mac>…"); returns `{project}`.
    case projectClone = "mobile.supermux.project.clone"

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

    // MARK: Agent launch (Claude in a new worktree)

    /// Reads the configured Claude commands plus one command's model catalog.
    case agentOptions = "mobile.supermux.agent.options"
    /// Creates a worktree named from a prompt and starts Claude in it.
    /// `attachment_paths` (``SupermuxMobileCapability/agentAttachmentsV1``)
    /// names images already stored here that Claude reads with the prompt.
    case agentStart = "mobile.supermux.agent.start"
    /// Stores one chunk of an image attached to an `agent.start` prompt, and
    /// answers the stored file's absolute path on the last chunk. Same store
    /// and chunk contract as ``terminalAttachmentUpload``, but no workspace
    /// exists yet, so it needs a Mac-wide ticket like `agent.start`.
    case agentAttachmentUpload = "mobile.supermux.agent.attachment.upload"

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
    /// Reads one bounded chunk of a regular file (base64), for another Mac's
    /// read-only preview.
    case filesRead = "mobile.supermux.files.read"
    /// Searches file contents under the resolved root (ripgrep, fixed
    /// arguments, bounded results).
    case filesSearch = "mobile.supermux.files.search"
    /// Reads the git status the desktop Files panel colors rows with.
    case filesGitStatus = "mobile.supermux.files.git_status"
    /// Leases a watcher on the workspace folder's own entries (not its
    /// subtree), the desktop Files panel's live refresh, for another Mac's
    /// panel: `supermux.files.updated` while the lease is renewed.
    case filesWatch = "mobile.supermux.files.watch"

    // MARK: Workspace selection / panes

    /// Selects one workspace on the Mac.
    case workspaceSelect = "mobile.supermux.workspace.select"
    /// Selects one terminal tab and its owning workspace on the Mac.
    case terminalSelect = "mobile.supermux.terminal.select"
    /// Selects one panel of any kind and its owning workspace on the Mac.
    case panelSelect = "mobile.supermux.panel.select"
    /// Closes one panel of any kind in a workspace.
    case paneClose = "mobile.supermux.pane.close"
    /// Creates a native Simulator panel in a workspace.
    case simulatorCreate = "mobile.supermux.simulator.create"
    /// Runs one control on a workspace's native Simulator panel: rotate left
    /// or right, or toggle the software keyboard or the appearance (another
    /// Mac's simulator viewer).
    case simulatorControl = "mobile.supermux.simulator.control"

    // MARK: Usage

    /// Reads the Claude Code + Codex rate-limit snapshot (read-only).
    case usageState = "mobile.supermux.usage.state"

    // MARK: Phone push

    /// Registers or removes this phone's APNs token on the paired Mac.
    case phonePushRegister = "mobile.supermux.phone_push.register"
    /// Reports this Mac's direct-APNs state (credentials present, key and team
    /// ids, registration count) to another Mac. Never returns secrets.
    case phonePushStatus = "mobile.supermux.phone_push.status"
    /// Shares direct-APNs credentials and phone registrations with this Mac.
    /// Accepted only from an admitted Mac peer, never from a phone.
    case phonePushShare = "mobile.supermux.phone_push.share"

    // MARK: Ports

    /// Lists this Mac's ports for another of the user's Macs (port forwarding):
    /// the ports its cmux workspaces listen on that loopback reaches, each with
    /// its workspace; with `include_other`, every other loopback listener's port
    /// too (for a manual forward). Served only to an admitted Mac peer.
    case portsList = "mobile.supermux.ports.list"

    // MARK: Terminal attachments

    /// Stores one chunk of a file pasted or dropped into another Mac's device
    /// mirror of a terminal here, and answers the stored file's absolute path
    /// on the last chunk, which that Mac types into the terminal. Same store
    /// and chunk contract as upstream's `mobile.task.attachment.upload`
    /// (`~/.cache/cmux/task-attachments`), without its Task Composer gate.
    case terminalAttachmentUpload = "mobile.supermux.terminal.attachment.upload"
    // MARK: Terminal streaming

    /// Names the terminals this connection mirrors (`surface_ids`): the host
    /// then sends `terminal.bytes` only for those, and never sheds them from
    /// the event queue (``SupermuxMobileCapability/terminalStreamV1``).
    /// Connection-scoped; a new connection starts topic-wide again.
    case terminalWatch = "mobile.supermux.terminal.watch"

    // MARK: Terminal actions

    /// Runs one terminal action (`action`: `clear_screen`, `reset`,
    /// `focus_in`, `focus_out`) on terminal `terminal_id` of `workspace_id`,
    /// forwarded by another Mac's device mirror of that terminal.
    case terminalAction = "mobile.supermux.terminal.action"

    /// The shared method-name prefix; the Mac router dispatches on it.
    public static let namespacePrefix = "mobile.supermux."

    /// Every method, in declaration order (derived from `CaseIterable`).
    public static let all: [SupermuxMobileMethod] = SupermuxMobileMethod.allCases
}

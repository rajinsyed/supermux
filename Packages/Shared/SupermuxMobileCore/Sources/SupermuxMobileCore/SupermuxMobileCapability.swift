/// A capability identifier the supermux macOS host advertises so the phone
/// can gate its UI.
///
/// Every iOS entry point stays hidden unless the host advertises the matching
/// capability — a fork phone paired with upstream cmux renders exactly
/// today's UI.
public enum SupermuxMobileCapability: String, CaseIterable, Codable, Sendable, Equatable {
    /// Projects list/CRUD/open/icon methods are served.
    case projectsV1 = "supermux.projects.v1"
    /// Workspace-list payloads may carry `supermux_activity`.
    case activityV1 = "supermux.activity.v1"
    /// Worktree list/create/open/remove methods are served.
    case worktreesV1 = "supermux.worktrees.v1"
    /// Terminal-preset CRUD/launch methods are served.
    case presetsV1 = "supermux.presets.v1"
    /// Changes (git) methods and the changes watcher are served.
    case changesV1 = "supermux.changes.v1"
    /// Run state/start/stop methods are served.
    case runV1 = "supermux.run.v1"
    /// Project-action execution is served.
    case actionsV1 = "supermux.actions.v1"
    /// File-browser methods are served.
    case filesV1 = "supermux.files.v1"
    /// Workspace and terminal selection stay synchronized with the Mac.
    case selectionSyncV1 = "supermux.selection_sync.v1"
    /// Workspace selection and focused panels of every kind stay synchronized.
    case selectionSyncV2 = "supermux.selection_sync.v2"
    /// Workspace pane close and Simulator creation methods are served.
    case panesV1 = "supermux.panes.v1"
    /// The paired Mac accepts this phone's APNs token for local push delivery.
    case phonePushV1 = "supermux.phone_push.v1"
    /// The read-only Claude Code + Codex usage-limits snapshot is served.
    case usageV1 = "supermux.usage.v1"
    /// Prompt-first worktree creation (`agent.options` / `agent.start`) is served.
    case agentLaunchV1 = "supermux.agent_launch.v1"
    /// Macs can share direct-APNs credentials and phone registrations
    /// (`phone_push.status` / `phone_push.share`) over the device link.
    case phonePushShareV1 = "supermux.phone_push_share.v1"
    /// Cross-Mac project setup (`project.probe` / `project.clone`) is served.
    case projectSetupV1 = "supermux.project_setup.v1"
    /// `mobile.terminal.input` takes `supermux_input`: ordered raw bytes,
    /// written to the PTY verbatim, and forwarded key presses, encoded by this
    /// Mac's own terminal state (Mac-to-Mac device mirrors).
    case terminalInputV1 = "supermux.terminal_input.v1"
    /// `device.workspace.terminal.create` takes `after_surface_id`: the new
    /// tab goes right of that terminal ("New Terminal to the Right" in another
    /// Mac's device mirror).
    case terminalPlacementV1 = "supermux.terminal_placement.v1"
    /// Read-only file browsing for another Mac's Files panel is served:
    /// `files.list {show_hidden}` (with the host's `home`), chunked
    /// `files.read`, `files.search` and `files.git_status`, all confined to
    /// the workspace's folder, and `files.watch` (`supermux.files.updated`
    /// when the folder's own entries change).
    case filesReadV1 = "supermux.files_read.v1"
    /// Port forwarding for the user's other Macs: their `tcp_connect` tunnel
    /// lanes reach this Mac's loopback, and `ports.list` /
    /// `supermux.ports.updated` are served. Withheld while the embedded
    /// browser is disabled by policy.
    case portForwardV1 = "supermux.port_forward.v1"
    /// Another Mac can show this Mac's simulators: `simulator.control`
    /// (rotate, software keyboard, appearance) is served and
    /// `simulator.create` takes `udid`.
    case remoteSimulatorV1 = "supermux.remote_simulator.v1"
    /// A file pasted or dropped into another Mac's device mirror of a
    /// terminal here is uploaded to this Mac (`terminal.attachment.upload`),
    /// so the path typed into the terminal names a file that exists here.
    case terminalAttachmentsV1 = "supermux.terminal_attachments.v1"
    /// Another Mac's device mirror streams a terminal like a local one:
    /// `terminal.watch` limits `terminal.bytes` to the mirrored terminals and
    /// keeps them lossless, and `mobile.terminal.replay` takes
    /// `supermux_resume_from_seq` (answering with the bytes since then while
    /// the host's byte tail still holds them) and reports `supermux_stream_epoch`.
    case terminalStreamV1 = "supermux.terminal_stream.v1"
    /// `mobile.terminal.size_policy.set` takes `supermux_preference`: a size
    /// mode picked on another Mac's mirror becomes this Mac's setting for all
    /// its terminals, as one picked here does.
    case terminalSizingPreferenceV1 = "supermux.terminal_sizing_preference.v1"
    /// Another Mac's device mirror of a terminal here forwards the bindings
    /// that change the terminal itself (`clear_screen`, `reset`) and its
    /// focus changes (`focus_in`, `focus_out`) with `terminal.action`, so
    /// they act on this terminal, not only on that Mac's view of it.
    case terminalActionsV1 = "supermux.terminal_actions.v1"

    /// Every capability, in declaration order (derived from `CaseIterable`).
    public static let all: [SupermuxMobileCapability] = SupermuxMobileCapability.allCases
}

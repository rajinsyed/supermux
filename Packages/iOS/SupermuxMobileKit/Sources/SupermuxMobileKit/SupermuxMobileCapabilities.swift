public import SupermuxMobileCore

/// The capability gate for every supermux entry point on the phone.
///
/// Parses the host's raw capability strings (from `mobile.host.status`) into
/// one accessor per `supermux.*.v1` capability. Every supermux screen,
/// section, and toolbar entry is hidden unless its accessor is `true` — a
/// fork phone paired with an upstream cmux Mac renders exactly today's UI.
public struct SupermuxMobileCapabilities: Sendable, Equatable {
    private let advertised: Set<String>

    /// Parses the host's advertised capability strings.
    ///
    /// Unknown strings are ignored; duplicates collapse.
    ///
    /// - Parameter hostCapabilities: The raw capability identifiers the
    ///   connected Mac advertises.
    public init(hostCapabilities: some Sequence<String>) {
        self.advertised = Set(hostCapabilities)
    }

    /// Whether the host advertises the given supermux capability.
    /// - Parameter capability: The capability to check.
    public func contains(_ capability: SupermuxMobileCapability) -> Bool {
        advertised.contains(capability.rawValue)
    }

    /// `supermux.projects.v1`: projects list/CRUD/open/icon are served.
    public var supportsProjects: Bool { contains(.projectsV1) }
    /// `supermux.activity.v1`: workspace payloads may carry `supermux_activity`.
    public var supportsActivity: Bool { contains(.activityV1) }
    /// `supermux.worktrees.v1`: worktree list/create/open/remove are served.
    public var supportsWorktrees: Bool { contains(.worktreesV1) }
    /// `supermux.presets.v1`: terminal-preset CRUD/launch are served.
    public var supportsPresets: Bool { contains(.presetsV1) }
    /// `supermux.changes.v1`: changes (git) methods and the watcher are served.
    public var supportsChanges: Bool { contains(.changesV1) }
    /// `supermux.run.v1`: run state/start/stop are served.
    public var supportsRun: Bool { contains(.runV1) }
    /// `supermux.actions.v1`: project-action execution is served.
    public var supportsActions: Bool { contains(.actionsV1) }
    /// `supermux.files.v1`: file-browser methods are served.
    public var supportsFiles: Bool { contains(.filesV1) }
    /// Whether workspace selection synchronization is available in either version.
    public var supportsSelectionSync: Bool {
        contains(.selectionSyncV1) || contains(.selectionSyncV2)
    }
    /// `supermux.selection_sync.v2`: every Mac panel kind stays in sync.
    public var supportsPanelSelectionSync: Bool { contains(.selectionSyncV2) }
    /// `supermux.panes.v1`: pane close and Simulator creation are served.
    public var supportsPanes: Bool { contains(.panesV1) }
    /// `supermux.phone_push.v1`: the paired Mac accepts this phone's APNs token.
    public var supportsPhonePush: Bool { contains(.phonePushV1) }
    /// `supermux.usage.v1`: the read-only usage-limits snapshot is served.
    public var supportsUsage: Bool { contains(.usageV1) }
    /// `supermux.agent_launch.v1`: prompt-first worktree creation that starts
    /// Claude (`agent.options` / `agent.start`) is served.
    public var supportsAgentLaunch: Bool { contains(.agentLaunchV1) }
    /// The Mac shares push credentials and phone registrations with the
    /// user's other Macs (Mac-to-Mac only; no phone UI depends on it).
    public var supportsPhonePushShare: Bool { contains(.phonePushShareV1) }
    /// The Mac serves cross-Mac project setup (`project.probe` / `project.clone`).
    public var supportsProjectSetup: Bool { contains(.projectSetupV1) }
    /// The Mac takes device-mirror input batches (Mac-to-Mac only; no phone
    /// UI depends on it).
    public var supportsTerminalInput: Bool { contains(.terminalInputV1) }
    /// The Mac places a mirror's new tab right of a given terminal (Mac-to-Mac
    /// only; no phone UI depends on it).
    public var supportsTerminalPlacement: Bool { contains(.terminalPlacementV1) }
    /// The Mac serves read-only file browsing for another Mac's Files panel
    /// (Mac-to-Mac only; no phone UI depends on it).
    public var supportsFilesRead: Bool { contains(.filesReadV1) }
}

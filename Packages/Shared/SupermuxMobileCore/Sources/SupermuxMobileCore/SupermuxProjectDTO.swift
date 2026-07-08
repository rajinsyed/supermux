/// Wire representation of a registered supermux project.
///
/// Mirrors the Mac's `SupermuxProject` model. Only the identity fields are
/// required; every other field is optional so old peers tolerate additions
/// and omissions. Dates travel as Unix seconds (`Double`) to stay
/// encoder-strategy-agnostic.
public struct SupermuxProjectDTO: Codable, Sendable, Equatable {
    /// Stable project identity (UUID string).
    public var id: String
    /// User-visible display name.
    public var name: String
    /// Absolute path to the project root on the Mac.
    public var rootPath: String
    /// Accent color as `#RRGGBB`, or `nil` for the neutral default.
    public var colorHex: String?
    /// SF Symbol name for the avatar, or `nil` for a letter avatar.
    public var iconSymbol: String?
    /// Whether a custom icon file exists Mac-side (fetch it via
    /// ``SupermuxMobileMethod/projectIcon``); the path itself never travels.
    public var hasCustomIcon: Bool?
    /// Branch new worktrees are created from; `nil` uses `HEAD`.
    public var defaultBranch: String?
    /// Directory (relative to ``rootPath``) holding supermux-managed worktrees.
    public var worktreesDirName: String?
    /// Shell commands for the project's run action.
    public var runCommands: [String]?
    /// Shell commands run in a fresh worktree right after creation.
    public var setupCommands: [String]?
    /// Shell commands run in a worktree right before removal.
    public var teardownCommands: [String]?
    /// Named custom actions launchable from the project.
    public var actions: [SupermuxProjectActionDTO]?
    /// Registration time, Unix seconds.
    public var createdAt: Double?
    /// Last time a workspace was opened from the project, Unix seconds.
    public var lastOpenedAt: Double?
    /// Path (relative to ``rootPath``) of the repo-shipped `config.json`
    /// managing the run/setup/teardown/actions fields, e.g.
    /// `".supermux/config.json"` — the read-only marker: when present those
    /// fields are config-owned and `project.update` rejects patches to them,
    /// exactly like the desktop editor disables them. `nil` when user-owned.
    public var configPath: String?

    /// Creates a project DTO.
    /// - Parameters:
    ///   - id: Stable project identity (UUID string).
    ///   - name: Display name.
    ///   - rootPath: Absolute project root path on the Mac.
    ///   - colorHex: Optional `#RRGGBB` accent.
    ///   - iconSymbol: Optional SF Symbol avatar.
    ///   - hasCustomIcon: Whether a custom icon file exists Mac-side.
    ///   - defaultBranch: Optional base branch for new worktrees.
    ///   - worktreesDirName: Optional worktree container directory name.
    ///   - runCommands: Optional run-action commands.
    ///   - setupCommands: Optional fresh-worktree setup commands.
    ///   - teardownCommands: Optional pre-removal teardown commands.
    ///   - actions: Optional named custom actions.
    ///   - createdAt: Optional registration time, Unix seconds.
    ///   - lastOpenedAt: Optional last-opened time, Unix seconds.
    ///   - configPath: Optional relative path of the managing `config.json`
    ///     (the read-only marker for the config-owned fields).
    public init(
        id: String,
        name: String,
        rootPath: String,
        colorHex: String? = nil,
        iconSymbol: String? = nil,
        hasCustomIcon: Bool? = nil,
        defaultBranch: String? = nil,
        worktreesDirName: String? = nil,
        runCommands: [String]? = nil,
        setupCommands: [String]? = nil,
        teardownCommands: [String]? = nil,
        actions: [SupermuxProjectActionDTO]? = nil,
        createdAt: Double? = nil,
        lastOpenedAt: Double? = nil,
        configPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
        self.hasCustomIcon = hasCustomIcon
        self.defaultBranch = defaultBranch
        self.worktreesDirName = worktreesDirName
        self.runCommands = runCommands
        self.setupCommands = setupCommands
        self.teardownCommands = teardownCommands
        self.actions = actions
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.configPath = configPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case rootPath = "root_path"
        case colorHex = "color_hex"
        case iconSymbol = "icon_symbol"
        case hasCustomIcon = "has_custom_icon"
        case defaultBranch = "default_branch"
        case worktreesDirName = "worktrees_dir_name"
        case runCommands = "run_commands"
        case setupCommands = "setup_commands"
        case teardownCommands = "teardown_commands"
        case actions
        case createdAt = "created_at"
        case lastOpenedAt = "last_opened_at"
        case configPath = "config_path"
    }
}

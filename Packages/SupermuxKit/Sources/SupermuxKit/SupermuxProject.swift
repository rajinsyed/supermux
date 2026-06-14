public import Foundation

/// A sticky, registered repository or folder shown in the supermux "Projects"
/// sidebar section.
///
/// Unlike a cmux workspace (which lives and dies with the session), a project
/// persists forever in ``SupermuxProjectStore`` until the user removes it.
/// From a project the user can open a local workspace at ``rootPath`` or
/// create an isolated git worktree checkout.
public struct SupermuxProject: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, preserved across app restarts.
    public let id: UUID
    /// User-visible display name; defaults to the folder's basename.
    public var name: String
    /// Absolute path to the project root (usually a git repository root).
    public var rootPath: String
    /// Accent color as `#RRGGBB`, or `nil` for the neutral default.
    public var colorHex: String?
    /// SF Symbol name for the project avatar, or `nil` for a letter avatar.
    public var iconSymbol: String?
    /// Branch new worktrees are created from when set; `nil` uses `HEAD`.
    public var defaultBranch: String?
    /// Directory (relative to ``rootPath``) that holds supermux-managed
    /// worktrees. Matches the piggycode convention.
    public var worktreesDirName: String
    /// Shell commands for the project's run action (started/stopped with ⌘G).
    public var runCommands: [String]
    /// Shell commands run in a fresh worktree right after it is created
    /// (e.g. `bun install`, `cp "$SUPERSET_ROOT_PATH/.env" .env`). Each entry
    /// may itself span multiple lines; they run in the new worktree's terminal
    /// with the worktree-environment variables exported.
    public var setupCommands: [String]
    /// Shell commands run in a worktree right before it is removed (cleanup,
    /// e.g. stopping containers). Run headless in the worktree directory with
    /// the worktree-environment variables exported; failures never block removal.
    public var teardownCommands: [String]
    /// Named custom actions / terminal presets launchable from the project.
    public var actions: [SupermuxProjectAction]
    /// When the project was registered.
    public var createdAt: Date
    /// When a workspace was last opened from this project, for recency sorting.
    public var lastOpenedAt: Date?

    /// Creates a project record.
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh UUID.
    ///   - name: Display name; pass the folder basename for new projects.
    ///   - rootPath: Absolute path to the project root.
    ///   - colorHex: Accent color as `#RRGGBB`, or `nil` for the default.
    ///   - iconSymbol: SF Symbol avatar, or `nil` for a letter avatar.
    ///   - defaultBranch: Base branch for new worktrees; `nil` uses `HEAD`.
    ///   - worktreesDirName: Worktree container directory; defaults to `.worktrees`.
    ///   - runCommands: Run-action commands; defaults to none.
    ///   - setupCommands: Commands run in a fresh worktree after creation; defaults to none.
    ///   - teardownCommands: Commands run in a worktree before removal; defaults to none.
    ///   - actions: Named custom actions / terminal presets; defaults to none.
    ///   - createdAt: Registration date; defaults to now.
    ///   - lastOpenedAt: Last-opened date; defaults to `nil`.
    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        colorHex: String? = nil,
        iconSymbol: String? = nil,
        defaultBranch: String? = nil,
        worktreesDirName: String = ".worktrees",
        runCommands: [String] = [],
        setupCommands: [String] = [],
        teardownCommands: [String] = [],
        actions: [SupermuxProjectAction] = [],
        createdAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
        self.defaultBranch = defaultBranch
        self.worktreesDirName = worktreesDirName
        self.runCommands = runCommands
        self.setupCommands = setupCommands
        self.teardownCommands = teardownCommands
        self.actions = actions
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }

    /// Absolute path of the directory that holds this project's worktrees.
    public var worktreesDirPath: String {
        (rootPath as NSString).appendingPathComponent(worktreesDirName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, colorHex, iconSymbol, defaultBranch
        case worktreesDirName, runCommands, setupCommands, teardownCommands
        case actions, createdAt, lastOpenedAt
    }

    /// Decodes a project, tolerating older records: `worktreesDirName`,
    /// `runCommands`, `setupCommands`, `teardownCommands`, `actions`, and
    /// `createdAt` fall back to sensible defaults when absent so forward/backward
    /// migrations stay lossless.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        worktreesDirName = try container.decodeIfPresent(String.self, forKey: .worktreesDirName) ?? ".worktrees"
        runCommands = try container.decodeIfPresent([String].self, forKey: .runCommands) ?? []
        setupCommands = try container.decodeIfPresent([String].self, forKey: .setupCommands) ?? []
        teardownCommands = try container.decodeIfPresent([String].self, forKey: .teardownCommands) ?? []
        actions = try container.decodeIfPresent([SupermuxProjectAction].self, forKey: .actions) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }
}

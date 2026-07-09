import Foundation
public import SupermuxMobileCore

/// Parsed `#RRGGBB` accent color, as normalized RGB components.
///
/// Pure value parsing so the avatar tint is unit-testable without SwiftUI;
/// the views build a `Color` from these components.
public struct SupermuxAvatarRGB: Equatable, Sendable {
    /// Red component in `0...1`.
    public let red: Double
    /// Green component in `0...1`.
    public let green: Double
    /// Blue component in `0...1`.
    public let blue: Double

    /// Parses a six-digit hex color, with or without a leading `#`.
    /// Anything else (shorthand, alpha, garbage) returns `nil` so the caller
    /// falls back to the neutral default.
    /// - Parameter hex: The color string, e.g. `#3B82F6`.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") {
            digits = digits.dropFirst()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.red = Double((value >> 16) & 0xFF) / 255
        self.green = Double((value >> 8) & 0xFF) / 255
        self.blue = Double(value & 0xFF) / 255
    }
}

/// Immutable value snapshot of one project's run state, projected from the
/// run store for the row's indicator and start/stop control. `nil` on the
/// row means the run UI is hidden entirely (no `supermux.run.v1`, or the
/// project has no run command configured).
public struct SupermuxProjectRunState: Equatable, Sendable {
    /// Whether the project's run command is currently running on the Mac.
    public let isRunning: Bool
    /// The running command, when the Mac reported one.
    public let command: String?

    /// Memberwise initializer.
    /// - Parameters:
    ///   - isRunning: Whether the run command is currently running.
    ///   - command: The running command, if any.
    public init(isRunning: Bool, command: String? = nil) {
        self.isRunning = isRunning
        self.command = command
    }
}

/// Immutable value snapshot of one project row in the phone's Projects
/// section. Rows below the shell's `List` boundary receive ONLY this (plus
/// closure action bundles) — never a store reference — per the repo's
/// snapshot-boundary rule.
public struct SupermuxProjectRowSnapshot: Equatable, Identifiable, Sendable {
    /// Stable project identity (UUID string, from the DTO).
    public let id: String
    /// User-visible display name.
    public let name: String
    /// Absolute path to the project root on the Mac.
    public let rootPath: String
    /// SF Symbol avatar, or `nil` for the letter avatar.
    public let iconSymbol: String?
    /// Parsed accent color, or `nil` for the neutral default.
    public let avatarRGB: SupermuxAvatarRGB?
    /// Whether a custom icon is fetchable via `mobile.supermux.project.icon`.
    public let hasCustomIcon: Bool
    /// Branch new worktrees are created from, when the Mac reported one.
    public let defaultBranch: String?
    /// First grapheme of the name, uppercased, for the letter avatar.
    public let avatarLetter: String
    /// Worktree count badge: the store-derived count once a worktrees fetch
    /// has run for this project, or `nil` (badge hidden) before real data
    /// exists — never a made-up zero badge.
    public let worktreeCount: Int?
    /// Open-workspace count badge: the number of ``openWorkspaces``, or `nil`
    /// when there are none (badge hidden, never a zero badge).
    public let openWorkspaceCount: Int?
    /// The open workspaces nested under this project (§6
    /// `supermux_project_id` join), in the shell's row order. Rendered by the
    /// project detail's Workspaces section.
    public let openWorkspaces: [SupermuxProjectWorkspaceRowSnapshot]
    /// The project's configured run commands, RAW and in DTO order — the
    /// start menu's `command_id` is the 0-based index into exactly this
    /// array (blank entries are skipped for display but never re-indexed).
    public let runCommands: [String]
    /// The project's named custom actions, for the detail screen's Actions
    /// section.
    public let actions: [SupermuxProjectActionDTO]
    /// The run-store-derived run state, or `nil` when the run UI is hidden
    /// (no `supermux.run.v1`, or no run command configured).
    public let run: SupermuxProjectRunState?

    /// Projects a wire DTO into the row snapshot.
    /// - Parameters:
    ///   - project: The project as fetched from the Mac.
    ///   - openWorkspaces: The open workspaces whose `supermux_project_id`
    ///     matches this project. Defaults to none.
    ///   - worktreeCount: The store-derived worktree count, or `nil` before a
    ///     worktrees fetch has run (badge hidden). Defaults to `nil`.
    ///   - run: The run-store-derived run state, or `nil` (run UI hidden).
    ///     Defaults to `nil`.
    public init(
        project: SupermuxProjectDTO,
        openWorkspaces: [SupermuxProjectWorkspaceRowSnapshot] = [],
        worktreeCount: Int? = nil,
        run: SupermuxProjectRunState? = nil
    ) {
        self.id = project.id
        self.name = project.name
        self.rootPath = project.rootPath
        self.iconSymbol = project.iconSymbol
        self.avatarRGB = project.colorHex.flatMap(SupermuxAvatarRGB.init(hex:))
        self.hasCustomIcon = project.hasCustomIcon ?? false
        self.defaultBranch = project.defaultBranch
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarLetter = trimmed.first.map { String($0).uppercased() } ?? "?"
        self.worktreeCount = worktreeCount
        self.openWorkspaceCount = openWorkspaces.isEmpty ? nil : openWorkspaces.count
        self.openWorkspaces = openWorkspaces
        self.runCommands = project.runCommands ?? []
        self.actions = project.actions ?? []
        self.run = run
    }
}

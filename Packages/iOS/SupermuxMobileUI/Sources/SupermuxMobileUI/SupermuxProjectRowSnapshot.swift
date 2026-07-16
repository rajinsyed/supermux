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

/// The nested-worktree slice of an expanded project row (m6-f1 inline
/// nesting, mirroring the mac sidebar's disclosure). An immutable value —
/// the section-owned worktrees store never crosses the `List` boundary.
public enum SupermuxProjectNestedWorktrees: Equatable, Sendable {
    /// No worktree data can exist: project collapsed, no live session, or
    /// the host lacks `supermux.worktrees.v1` (the rows simply don't render).
    case unavailable
    /// Expanded with the fetch-on-expand still in flight.
    case loading
    /// Expanded and fetched: the project's UNOPENED worktrees, in the Mac's
    /// order (open ones are already represented by nested workspace rows).
    case loaded([SupermuxWorktreeRowSnapshot])
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
    /// The custom icon's CONTENT etag as carried by the projects list (the
    /// same value the `project.icon` RPC answers), or `nil` while the wire
    /// doesn't surface one. This is the avatar's icon-change signal: a
    /// Mac-side icon replacement keeps `hasCustomIcon == true` but changes
    /// the etag, so the avatar's fetch task re-keys on it — without it a
    /// changed icon would render stale indefinitely.
    public let iconETag: String?
    /// Branch new worktrees are created from, when the Mac reported one.
    public let defaultBranch: String?
    /// First grapheme of the name, uppercased, for the letter avatar.
    public let avatarLetter: String
    /// UNOPENED-worktree count for the row's capsule (the mac capsule counts
    /// only worktrees without an open workspace): derived from a worktrees
    /// fetch — an expanded project's live session or the section's one-shot
    /// per-project seed — or `nil` (capsule hidden) before real data exists,
    /// never a made-up zero badge.
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
    /// (no `supermux.run.v1`, or no run command configured). Feeds the detail
    /// screen's Run section; the LIST row renders no run control (mac-sidebar
    /// parity — the mac project row carries no run affordance either).
    public let run: SupermuxProjectRunState?
    /// Whether this project's inline disclosure is open (phone-local,
    /// UserDefaults-persisted — NOT the Mac's `section_collapsed`).
    public let isExpanded: Bool
    /// The nested unopened-worktree rows for an expanded project; always
    /// ``SupermuxProjectNestedWorktrees/unavailable`` while collapsed.
    public let nestedWorktrees: SupermuxProjectNestedWorktrees

    /// Projects a wire DTO into the row snapshot.
    /// - Parameters:
    ///   - project: The project as fetched from the Mac.
    ///   - openWorkspaces: The open workspaces whose `supermux_project_id`
    ///     matches this project. Defaults to none.
    ///   - worktreeCount: The store-derived worktree count, or `nil` before a
    ///     worktrees fetch has run (badge hidden). Defaults to `nil`.
    ///   - iconETag: The custom icon's content etag from the projects list
    ///     (`icon_etag`), or `nil` while the wire doesn't surface one —
    ///     populate from the DTO once the field lands there. Defaults to
    ///     `nil`.
    ///   - run: The run-store-derived run state, or `nil` (run UI hidden).
    ///     Defaults to `nil`.
    ///   - isExpanded: Whether the inline disclosure is open. Defaults to
    ///     collapsed.
    ///   - nestedWorktrees: The nested unopened-worktree slice. Defaults to
    ///     ``SupermuxProjectNestedWorktrees/unavailable``.
    public init(
        project: SupermuxProjectDTO,
        openWorkspaces: [SupermuxProjectWorkspaceRowSnapshot] = [],
        worktreeCount: Int? = nil,
        iconETag: String? = nil,
        run: SupermuxProjectRunState? = nil,
        isExpanded: Bool = false,
        nestedWorktrees: SupermuxProjectNestedWorktrees = .unavailable
    ) {
        self.id = project.id
        self.name = project.name
        self.rootPath = project.rootPath
        self.iconSymbol = project.iconSymbol
        self.avatarRGB = project.colorHex.flatMap(SupermuxAvatarRGB.init(hex:))
        self.hasCustomIcon = project.hasCustomIcon ?? false
        self.iconETag = iconETag
        self.defaultBranch = project.defaultBranch
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarLetter = trimmed.first.map { String($0).uppercased() } ?? "?"
        self.worktreeCount = worktreeCount
        self.openWorkspaceCount = openWorkspaces.isEmpty ? nil : openWorkspaces.count
        self.openWorkspaces = openWorkspaces
        self.runCommands = project.runCommands ?? []
        self.actions = project.actions ?? []
        self.run = run
        self.isExpanded = isExpanded
        self.nestedWorktrees = nestedWorktrees
    }
}

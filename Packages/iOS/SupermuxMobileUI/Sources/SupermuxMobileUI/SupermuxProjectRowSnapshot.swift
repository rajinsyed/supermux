public import Foundation
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
    /// Worktree count badge. Reserved: stays `nil` (badge hidden) until the
    /// worktrees milestone supplies real values.
    public let worktreeCount: Int?
    /// Open-workspace count badge. Reserved: stays `nil` (badge hidden) until
    /// the workspace-list `supermux_project_id` augmentation lands.
    public let openWorkspaceCount: Int?

    /// Projects a wire DTO into the row snapshot.
    /// - Parameter project: The project as fetched from the Mac.
    public init(project: SupermuxProjectDTO) {
        self.id = project.id
        self.name = project.name
        self.rootPath = project.rootPath
        self.iconSymbol = project.iconSymbol
        self.avatarRGB = project.colorHex.flatMap(SupermuxAvatarRGB.init(hex:))
        self.hasCustomIcon = project.hasCustomIcon ?? false
        self.defaultBranch = project.defaultBranch
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarLetter = trimmed.first.map { String($0).uppercased() } ?? "?"
        self.worktreeCount = nil
        self.openWorkspaceCount = nil
    }
}

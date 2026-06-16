public import Foundation

/// An immutable, value-typed snapshot of one switchable workspace, rendered as a
/// single card in the supermux workspace switcher (the Cmd+`-held, app-switcher
/// style overlay).
///
/// The host app builds these from its live `TabManager.tabs` at the moment the
/// switcher opens and freezes them for the whole hold session, so the strip never
/// reshuffles while the user is cycling. The card view consumes only this value
/// plus an optional cached preview image — it never holds a reference to a live
/// workspace/store (see the snapshot-boundary rule in CLAUDE.md), which keeps the
/// `LazyHStack` of cards cheap to diff.
public struct SupermuxWorkspaceSwitcherItem: Identifiable, Hashable, Sendable {
    /// The cmux workspace identifier (session-scoped, stable within a session).
    public let id: UUID
    /// Display title (`customTitle ?? title`), already resolved by the host.
    public let title: String
    /// A secondary line: the git branch, else the working-directory basename.
    public let subtitle: String?
    /// Accent color as `#RRGGBB` — the workspace's custom color, else its owning
    /// project's color, else `nil` for the neutral default.
    public let accentColorHex: String?
    /// SF Symbol for the avatar when the workspace belongs to a project that has
    /// one; `nil` falls back to the monogram.
    public let iconSymbol: String?
    /// A single uppercase letter for the letter-avatar fallback.
    public let monogram: String
    /// The owning project's id, or `nil` for a standalone workspace.
    public let projectId: UUID?
    /// The owning project's display name, for a small project chip on the card.
    public let projectName: String?
    /// Whether this is the workspace that was active when the switcher opened
    /// (rendered at index 0, the "current" card).
    public let isCurrent: Bool

    /// Creates a switcher item.
    public init(
        id: UUID,
        title: String,
        subtitle: String? = nil,
        accentColorHex: String? = nil,
        iconSymbol: String? = nil,
        monogram: String = "",
        projectId: UUID? = nil,
        projectName: String? = nil,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.accentColorHex = accentColorHex
        self.iconSymbol = iconSymbol
        self.monogram = monogram
        self.projectId = projectId
        self.projectName = projectName
        self.isCurrent = isCurrent
    }

    /// Derives the monogram for a title: the first letter of the first
    /// alphanumeric word, uppercased, or `"#"` when the title has none.
    public static func monogram(for title: String) -> String {
        for character in title where character.isLetter || character.isNumber {
            return String(character).uppercased()
        }
        return "#"
    }
}

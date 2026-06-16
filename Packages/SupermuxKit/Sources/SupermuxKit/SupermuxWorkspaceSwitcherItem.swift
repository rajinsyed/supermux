public import Foundation

/// An immutable, value-typed snapshot of one switchable workspace, rendered as a
/// single card in the supermux workspace switcher (the Cmd+`-held, app-switcher
/// style overlay).
///
/// The host app builds these from its live `TabManager.tabs` at the moment the
/// switcher opens and freezes them for the whole hold session, so the strip never
/// reshuffles while the user is cycling. The card view consumes only this value
/// (including the terminal preview text captured here) — it never holds a
/// reference to a live workspace/store (see the snapshot-boundary rule in
/// CLAUDE.md), which keeps the row of cards cheap to diff.
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
    /// The last few non-empty lines of the terminal's live viewport text, used to
    /// render a faithful "mini terminal" preview. Empty for non-terminal panels or
    /// a blank/cold terminal, in which case the card shows a metadata fallback.
    /// Text (not a pixel screenshot) because background workspaces stop rendering —
    /// their GPU surface is stale, but libghostty keeps the text grid current.
    public let previewLines: [String]
    /// The owning project, when the workspace resolves to one — used to render the
    /// project's avatar badge on the card (matching the sidebar via
    /// ``SupermuxProjectAvatarView``). `nil` for a standalone workspace.
    public let project: SupermuxProject?
    /// The workspace's agent-activity state (working / needs input / ready / idle),
    /// shown as the card's status indicator so you can tell at a glance what each
    /// workspace is doing. `idle` shows no indicator.
    public let activity: SupermuxWorkspaceActivity

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
        isCurrent: Bool = false,
        previewLines: [String] = [],
        project: SupermuxProject? = nil,
        activity: SupermuxWorkspaceActivity = .idle
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
        self.previewLines = previewLines
        self.project = project
        self.activity = activity
    }

    /// Cleans raw terminal viewport text into the last few display lines for the
    /// compact mini-terminal preview: drops trailing blank lines so the prompt /
    /// most recent output anchors the preview, keeps at most `maxLines`, expands
    /// tabs, and caps line length to bound layout cost. Returns `[]` when there is
    /// no usable content (the caller then shows a metadata fallback card).
    public static func terminalPreviewLines(
        fromViewport text: String,
        maxLines: Int = 8,
        maxLineLength: Int = 240
    ) -> [String] {
        guard maxLines > 0, maxLineLength > 0 else { return [] }
        var lines = text
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return [] }
        return lines.suffix(maxLines).map { line in
            let expanded = line.replacingOccurrences(of: "\t", with: "  ")
            return expanded.count > maxLineLength ? String(expanded.prefix(maxLineLength)) : expanded
        }
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

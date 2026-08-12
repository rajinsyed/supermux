public import SwiftUI

/// Layout and colour tokens for the Claude harness screens.
///
/// Ported from remodex (Apache-2.0) — its metrics, not its assets or name.
/// Kept as one table so the sessions list, the new-session sheet, and the
/// chat screen cannot drift apart the way three files of inline literals
/// always eventually do.
///
/// lint:allow namespace-enum — a constant token table (data, not behavior).
public enum SupermuxClaudeStyle {
    /// Prose body size. Remodex measures every prose surface from one value
    /// (`AppFont.bodyPointSize = 15`) so bubbles, markdown, and the composer
    /// line up; the same reason applies here.
    public static let bodyPointSize: CGFloat = 15

    /// The user bubble's corner radius.
    public static let bubbleCornerRadius: CGFloat = 22

    /// Card and row corner radius (tool cards, diff summaries, chips).
    public static let cardCornerRadius: CGFloat = 16

    /// Tight spacing: within a row, between a glyph and its label.
    public static let tightSpacing: CGFloat = 12

    /// Loose spacing: between transcript groups and stacked cards.
    public static let looseSpacing: CGFloat = 16

    /// Horizontal screen margin.
    public static let horizontalMargin: CGFloat = 16

    /// Minimum empty space to the left of a user bubble, so a sent message
    /// never spans the full width and stays visually "from the right".
    public static let bubbleLeadingGutter: CGFloat = 60

    /// The session-list status dot's diameter.
    public static let statusDotSize: CGFloat = 10.5

    /// Prose body font.
    /// - Parameter weight: The requested weight.
    public static func body(weight: Font.Weight = .regular) -> Font {
        .system(size: bodyPointSize, weight: weight)
    }

    /// Monospaced font for command text, diffs, and tool output.
    /// - Parameter size: The point size.
    public static func mono(size: CGFloat = 13) -> Font {
        .system(size: size, design: .monospaced)
    }
}

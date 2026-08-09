public import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Design tokens for the supermux agent-chat surface.
///
/// The fork's chat redesign is a *quiet, borderless* surface: the transcript is
/// a single left-aligned column of text and one-line activity rows on the plain
/// system background, with only the user's own prompts wearing a bubble. Cards,
/// strokes, and fills are reserved for content that genuinely is a block —
/// diffs, shell output, permission prompts — and even those stay hairline-light.
///
/// Injected through the environment so hosts (and previews) can re-tint the
/// surface without touching the views.
public struct SupermuxChatTheme: Sendable, Equatable {
    // MARK: - Surfaces

    /// The transcript's page background. Deliberately the plain system
    /// background: agent prose reads as a document, not as a stack of cards.
    public var canvas: Color

    /// Fill for block surfaces that sit on ``canvas`` (diff cards, code blocks,
    /// shell output). One step of elevation, never more.
    public var elevatedFill: Color

    /// Fill for the user's own prompt bubble.
    public var outgoingFill: Color

    /// Foreground for text on ``outgoingFill``.
    public var outgoingText: Color

    /// Hairline for card borders and separators.
    public var hairline: Color

    // MARK: - Semantics

    /// Accent for interactive affordances and the send button.
    public var accent: Color

    /// Tint for a running/in-flight activity.
    public var running: Color

    /// Tint for a failed activity.
    public var failure: Color

    /// Tint for added diff lines.
    public var diffAdded: Color

    /// Tint for removed diff lines.
    public var diffRemoved: Color

    // MARK: - Metrics

    /// Horizontal screen margin for transcript content.
    public var horizontalMargin: CGFloat

    /// Vertical gap between top-level transcript rows. Remodex's timeline uses
    /// one uniform rhythm rather than per-role spacing.
    public var rowSpacing: CGFloat

    /// Corner radius of the user's prompt bubble.
    public var bubbleCornerRadius: CGFloat

    /// Corner radius of block cards (diffs, shell output, code).
    public var cardCornerRadius: CGFloat

    /// Minimum leading gutter kept clear to the left of a user bubble.
    public var outgoingLeadingGutter: CGFloat

    /// Creates a theme. Defaults match the remodex-derived light/dark palette.
    public init(
        canvas: Color = .supermuxChatCanvas,
        elevatedFill: Color = .supermuxChatElevatedFill,
        // The "neutral collapses to primary" rule: with no user tint chosen,
        // the outgoing bubble and every CTA are label-on-background — a black
        // bubble in light mode, white in dark.
        outgoingFill: Color = .supermuxChatLabel,
        outgoingText: Color = .supermuxChatCanvas,
        hairline: Color = .supermuxChatSeparator,
        accent: Color = .supermuxChatLabel,
        // The one branded warm tone, carried straight over: amber for
        // in-flight/attention, at 79.7% alpha in dark.
        running: Color = .supermuxChatAdaptive(
            light: Color(red: 1.0, green: 0.832, blue: 0.473),
            dark: Color(red: 1.0, green: 0.832, blue: 0.473).opacity(0.797)
        ),
        failure: Color = .red,
        // GitHub-style diff foregrounds.
        diffAdded: Color = .supermuxChatAdaptive(
            light: Color(red: 0.10, green: 0.50, blue: 0.22),
            dark: Color(red: 0.34, green: 0.83, blue: 0.39)
        ),
        diffRemoved: Color = .supermuxChatAdaptive(
            light: Color(red: 0.81, green: 0.13, blue: 0.18),
            dark: Color(red: 0.97, green: 0.32, blue: 0.29)
        ),
        horizontalMargin: CGFloat = 16,
        rowSpacing: CGFloat = 14,
        bubbleCornerRadius: CGFloat = 22,
        cardCornerRadius: CGFloat = 12,
        outgoingLeadingGutter: CGFloat = 60
    ) {
        self.canvas = canvas
        self.elevatedFill = elevatedFill
        self.outgoingFill = outgoingFill
        self.outgoingText = outgoingText
        self.hairline = hairline
        self.accent = accent
        self.running = running
        self.failure = failure
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.horizontalMargin = horizontalMargin
        self.rowSpacing = rowSpacing
        self.bubbleCornerRadius = bubbleCornerRadius
        self.cardCornerRadius = cardCornerRadius
        self.outgoingLeadingGutter = outgoingLeadingGutter
    }
}

extension EnvironmentValues {
    /// The active supermux chat theme.
    @Entry public var supermuxChatTheme = SupermuxChatTheme()
}

extension Color {
    /// A color that resolves per color scheme, for tokens whose light and dark
    /// appearances differ.
    ///
    /// - Parameters:
    ///   - light: The light-appearance color.
    ///   - dark: The dark-appearance color.
    /// - Returns: A dynamic color.
    public static func supermuxChatAdaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            }
        )
        #else
        return dark
        #endif
    }

    // The four system semantics the chat surface is built on, spelled once so
    // the package still builds for the macOS slice of its platform list (where
    // the `Color(.systemBackground)` shorthand does not exist).

    /// The page background.
    public static var supermuxChatCanvas: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(white: 0)
        #endif
    }

    /// One step of elevation above ``supermuxChatCanvas``.
    public static var supermuxChatElevatedFill: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(white: 0.11)
        #endif
    }

    /// The primary label color.
    public static var supermuxChatLabel: Color {
        #if canImport(UIKit)
        Color(uiColor: .label)
        #else
        .primary
        #endif
    }

    /// The standard hairline.
    public static var supermuxChatSeparator: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator)
        #else
        Color(white: 0.5).opacity(0.4)
        #endif
    }
}

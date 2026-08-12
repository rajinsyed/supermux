public import SwiftUI

/// The macOS design tokens for the Claude harness (remodex, densified).
///
/// remodex is an iPhone app: its 15pt body and 22–26pt radii read as oversized
/// inside a Mac split pane. Every size here is the macOS column of the design's
/// token table; the palettes (tool accent, diff colours) are kept verbatim so
/// the two apps stay visually related.
///
/// lint:allow namespace-type — constant token table (data, not behavior).
/// (lint:allow)
public enum SupermuxHarnessTokens {
    // MARK: - Type scale (base sizes; scaled through GlobalFontMagnification)

    public static let body: CGFloat = 13
    public static let callout: CGFloat = 12.5
    public static let subheadline: CGFloat = 12
    public static let footnote: CGFloat = 11
    public static let caption: CGFloat = 10
    public static let caption2: CGFloat = 9
    public static let headline: CGFloat = 13
    public static let title3: CGFloat = 15

    // MARK: - Radii

    /// User prompt bubble.
    public static let bubbleRadius: CGFloat = 14
    /// Composer card.
    public static let composerRadius: CGFloat = 16
    /// Plan / todo / tool cards.
    public static let cardRadius: CGFloat = 14
    /// Accessory chips and pills.
    public static let chipRadius: CGFloat = 12
    /// File-change boxes, diff frames, attachments.
    public static let fileBoxRadius: CGFloat = 8
    /// Hairline stroke width used on every card and chip.
    public static let hairline: CGFloat = 0.5

    // MARK: - Spacing scale

    public static let spacing2: CGFloat = 2
    public static let spacing4: CGFloat = 4
    public static let spacing6: CGFloat = 6
    public static let spacing8: CGFloat = 8
    public static let spacing10: CGFloat = 10
    public static let spacing12: CGFloat = 12

    /// Vertical gap between transcript rows.
    public static let rowSpacing: CGFloat = 10
    /// Leading gutter reserved for the timeline glyph column.
    public static let timelineGutter: CGFloat = 12
    /// Maximum readable transcript column width.
    public static let transcriptMaxWidth: CGFloat = 760

    // MARK: - Palette constants

    /// remodex's tool-call accent, kept verbatim (Apache-2.0 clean).
    public static let toolAccent = Color(
        .sRGB, red: 1.0, green: 0.831, blue: 0.471, opacity: 1
    )

    // MARK: - Motion

    public static let springResponse: Double = 0.34
    public static let springDamping: Double = 0.86
    public static let disclosureDuration: Double = 0.18

    public static var spring: Animation {
        .spring(response: springResponse, dampingFraction: springDamping)
    }

    public static var disclosure: Animation {
        .easeInOut(duration: disclosureDuration)
    }
}

/// The remodex GitHub-style unified diff palette, ported verbatim from
/// `TurnUnifiedDiffView.UnifiedDiffPalette` (UIKit dynamic colours become
/// theme-driven SwiftUI colours here).
///
/// lint:allow namespace-type — constant colour table. (lint:allow)
public enum SupermuxHarnessDiffPalette {
    public struct RowPalette: Sendable, Equatable {
        public let rowBackground: Color
        public let gutterBackground: Color
        public let gutterForeground: Color
    }

    public static func additionForeground(isDark: Bool) -> Color {
        isDark
            ? Color(.sRGB, red: 0.34, green: 0.83, blue: 0.39, opacity: 1)
            : Color(.sRGB, red: 0.10, green: 0.50, blue: 0.22, opacity: 1)
    }

    public static func deletionForeground(isDark: Bool) -> Color {
        isDark
            ? Color(.sRGB, red: 0.97, green: 0.32, blue: 0.29, opacity: 1)
            : Color(.sRGB, red: 0.81, green: 0.13, blue: 0.18, opacity: 1)
    }

    public static func addition(isDark: Bool) -> RowPalette {
        RowPalette(
            rowBackground: isDark
                ? Color(.sRGB, red: 0.18, green: 0.63, blue: 0.26, opacity: 0.18)
                : Color(.sRGB, red: 0.90, green: 1.00, blue: 0.93, opacity: 1),
            gutterBackground: isDark
                ? Color(.sRGB, red: 0.18, green: 0.63, blue: 0.26, opacity: 0.30)
                : Color(.sRGB, red: 0.82, green: 0.96, blue: 0.83, opacity: 1),
            gutterForeground: additionForeground(isDark: isDark)
        )
    }

    public static func deletion(isDark: Bool) -> RowPalette {
        RowPalette(
            rowBackground: isDark
                ? Color(.sRGB, red: 0.97, green: 0.32, blue: 0.29, opacity: 0.18)
                : Color(.sRGB, red: 1.00, green: 0.92, blue: 0.91, opacity: 1),
            gutterBackground: isDark
                ? Color(.sRGB, red: 0.97, green: 0.32, blue: 0.29, opacity: 0.30)
                : Color(.sRGB, red: 1.00, green: 0.84, blue: 0.84, opacity: 1),
            gutterForeground: deletionForeground(isDark: isDark)
        )
    }

    public static func context(theme: SupermuxHarnessTheme) -> RowPalette {
        RowPalette(
            rowBackground: .clear,
            gutterBackground: theme.surface.opacity(0.5),
            gutterForeground: theme.mutedText
        )
    }
}

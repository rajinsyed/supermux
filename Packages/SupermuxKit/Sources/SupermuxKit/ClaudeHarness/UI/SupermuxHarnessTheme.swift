public import AppKit
public import SwiftUI
import CmuxFoundation

/// The colour inputs the harness theme derives from.
///
/// The app target owns `PanelAppearance` (an app-internal type), so the mount
/// projects it onto this package-visible struct. Keeping the inputs primitive
/// also makes the resolve function unit-testable without AppKit panel state.
public struct SupermuxHarnessThemeInput: Sendable, Equatable {
    /// The Ghostty-derived panel background (may be translucent).
    public let backgroundColor: NSColor
    /// The readable foreground for that background.
    public let foregroundColor: NSColor
    /// The app accent colour.
    public let accentColor: NSColor
    /// The colour actually painted behind content (clear for transparency).
    public let contentBackgroundColor: NSColor
    /// `false` when the window is transparent and content must not paint an
    /// opaque page background.
    public let drawsContentBackground: Bool

    public init(
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        accentColor: NSColor,
        contentBackgroundColor: NSColor,
        drawsContentBackground: Bool
    ) {
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.accentColor = accentColor
        self.contentBackgroundColor = contentBackgroundColor
        self.drawsContentBackground = drawsContentBackground
    }
}

/// The resolved SwiftUI colour set for the native Claude harness.
///
/// Deliberately mirrors `AgentSessionWebTheme.resolve(appearance:)` blend math
/// (contrast-targeted overlay for borders, fractional blends for surfaces, the
/// same alpha ladder) so a native Claude panel and a webview Codex panel in the
/// same window read as one product under any Ghostty theme, opacity, or accent
/// setting.
public struct SupermuxHarnessTheme: Sendable, Equatable {
    public let isDark: Bool
    public let pageBackground: Color
    /// `true` when the page must stay transparent (window transparency on).
    public let pageIsTransparent: Bool
    /// Always-opaque page colour for surfaces that present *outside* the panel
    /// hierarchy (popovers) or must contrast with an accent fill (slider dots).
    /// `pageBackground` can be `.clear` under window transparency, which would
    /// let the system's own chrome show through with the wrong appearance.
    public let popoverBackground: Color
    public let surface: Color
    public let surfaceElevated: Color
    public let inputBackground: Color
    public let border: Color
    public let borderStrong: Color
    public let text: Color
    public let mutedText: Color
    public let softText: Color
    public let accent: Color
    public let accentSoft: Color
    public let danger: Color
    public let shadow: Color
    /// The remodex tool-call accent (`#FFD478`), used for running tool status
    /// and the tool glyph. Constant across themes by design.
    public let toolAccent: Color

    /// Resolves the theme from panel appearance inputs.
    public static func resolve(input: SupermuxHarnessThemeInput) -> SupermuxHarnessTheme {
        let base = input.backgroundColor.harnessOpaqueSRGB
        let isDark = !base.isLightColor
        let overlay: NSColor = isDark ? .white : .black
        let inverseOverlay: NSColor = isDark ? .black : .white
        let transparentContent = input.contentBackgroundColor.alphaComponent < 0.001
        let baseSurfaceAlpha: CGFloat = input.drawsContentBackground ? 0.72 : 0.34
        let elevatedSurfaceAlpha: CGFloat = input.drawsContentBackground ? 0.84 : 0.48
        let inputAlpha: CGFloat = input.drawsContentBackground ? 0.60 : 0.36
        let border = base.harnessThemeOverlay(
            targetContrast: isDark ? 1.62 : 1.34,
            of: overlay
        )
        let borderStrong = base.harnessThemeOverlay(
            targetContrast: isDark ? 2.12 : 1.64,
            of: overlay
        )
        let surface = base
            .blended(withFraction: isDark ? 0.05 : 0.03, of: overlay)?
            .withAlphaComponent(baseSurfaceAlpha)
            ?? base.withAlphaComponent(baseSurfaceAlpha)
        let surfaceElevated = base
            .blended(withFraction: isDark ? 0.08 : 0.05, of: overlay)?
            .withAlphaComponent(elevatedSurfaceAlpha)
            ?? base.withAlphaComponent(elevatedSurfaceAlpha)
        let inputFill = base
            .blended(withFraction: isDark ? 0.18 : 0.10, of: inverseOverlay)?
            .withAlphaComponent(inputAlpha)
            ?? base.withAlphaComponent(inputAlpha)
        let foreground = input.foregroundColor
        let danger = NSColor(hex: isDark ? "#FF8D7E" : "#B3261E") ?? .systemRed
        return SupermuxHarnessTheme(
            isDark: isDark,
            pageBackground: Color(
                nsColor: transparentContent ? .clear : input.contentBackgroundColor
            ),
            pageIsTransparent: transparentContent,
            popoverBackground: Color(nsColor: base),
            surface: Color(nsColor: surface),
            surfaceElevated: Color(nsColor: surfaceElevated),
            inputBackground: Color(nsColor: inputFill),
            border: Color(
                nsColor: border.withAlphaComponent(border.alphaComponent * 0.72)
            ),
            borderStrong: Color(nsColor: borderStrong),
            text: Color(nsColor: foreground),
            mutedText: Color(nsColor: foreground.withAlphaComponent(0.58)),
            softText: Color(nsColor: foreground.withAlphaComponent(0.78)),
            accent: Color(nsColor: input.accentColor),
            accentSoft: Color(
                nsColor: input.accentColor.withAlphaComponent(isDark ? 0.20 : 0.16)
            ),
            danger: Color(nsColor: danger),
            shadow: Color.black.opacity(isDark ? 0.20 : 0.10),
            // remodex's `command.colorset` ships a dark variant at 0.797 alpha;
            // full-strength #FFD478 glows too hard on dark backgrounds.
            toolAccent: isDark
                ? SupermuxHarnessTokens.toolAccent.opacity(0.797)
                : SupermuxHarnessTokens.toolAccent
        )
    }

    /// A neutral fallback used by previews and by any call site that has no
    /// panel appearance yet.
    public static let fallback = SupermuxHarnessTheme.resolve(
        input: SupermuxHarnessThemeInput(
            backgroundColor: NSColor(hex: "#1E1E22") ?? .black,
            foregroundColor: NSColor(hex: "#E6E6E6") ?? .white,
            accentColor: .controlAccentColor,
            contentBackgroundColor: NSColor(hex: "#1E1E22") ?? .black,
            drawsContentBackground: true
        )
    )
}

extension NSColor {
    /// Opaque sRGB copy; blends and contrast maths need a defined space.
    var harnessOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    /// The overlay alpha that reaches `targetContrast` against this colour.
    ///
    /// Same binary search as the app's `markdownThemeOverlay(targetContrast:of:)`;
    /// duplicated here because that helper lives in the app target and packages
    /// cannot import it.
    func harnessThemeOverlay(targetContrast: CGFloat, of color: NSColor) -> NSColor {
        let base = harnessOpaqueSRGB
        let overlay = color.harnessOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1
        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: overlay) ?? base
            if candidate.harnessContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }
        return overlay.withAlphaComponent(result)
    }

    var harnessRelativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func harnessContrastRatio(with other: NSColor) -> Double {
        let first = harnessRelativeLuminance
        let second = other.harnessRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

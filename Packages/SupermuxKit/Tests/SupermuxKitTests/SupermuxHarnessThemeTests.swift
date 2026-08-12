import AppKit
import Testing
@testable import SupermuxKit

/// Theme resolution parity with `AgentSessionWebTheme`. A native Claude panel
/// and a webview Codex panel share one window, so a divergence here is visible
/// as two different products side by side.
struct SupermuxHarnessThemeTests {
    private func input(
        background: String,
        foreground: String = "#E6E6E6",
        drawsContentBackground: Bool = true
    ) -> SupermuxHarnessThemeInput {
        let base = NSColor(hex: background)!
        return SupermuxHarnessThemeInput(
            backgroundColor: base,
            foregroundColor: NSColor(hex: foreground)!,
            accentColor: .controlAccentColor,
            contentBackgroundColor: drawsContentBackground ? base : .clear,
            drawsContentBackground: drawsContentBackground
        )
    }

    @Test func darkBackgroundResolvesDarkTheme() {
        let theme = SupermuxHarnessTheme.resolve(input: input(background: "#1E1E22"))
        #expect(theme.isDark)
        #expect(!theme.pageIsTransparent)
    }

    @Test func lightBackgroundResolvesLightTheme() {
        let theme = SupermuxHarnessTheme.resolve(
            input: input(background: "#FFFFFF", foreground: "#1A1A1A")
        )
        #expect(!theme.isDark)
    }

    @Test func transparentContentBackgroundKeepsThePageClear() {
        let theme = SupermuxHarnessTheme.resolve(
            input: input(background: "#1E1E22", drawsContentBackground: false)
        )
        #expect(theme.pageIsTransparent)
    }

    /// The border overlay is a contrast search, not a fixed alpha: a border that
    /// is legible on `#1E1E22` is invisible on `#000000` if it is hardcoded.
    @Test func borderOverlayReachesItsContrastTarget() {
        let base = NSColor(hex: "#1E1E22")!.harnessOpaqueSRGB
        let overlay = base.harnessThemeOverlay(targetContrast: 1.62, of: .white)
        let blended = base.blended(withFraction: overlay.alphaComponent, of: .white)!
        #expect(blended.harnessContrastRatio(with: base) >= 1.6)
    }

    @Test func contrastRatioIsSymmetricAndBounded() {
        let black = NSColor(hex: "#000000")!
        let white = NSColor(hex: "#FFFFFF")!
        let forward = black.harnessContrastRatio(with: white)
        let backward = white.harnessContrastRatio(with: black)
        #expect(abs(forward - backward) < 0.0001)
        #expect(forward > 20.9)
        #expect(black.harnessContrastRatio(with: black) == 1)
    }
}

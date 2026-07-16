import AppKit
import Testing
@testable import SupermuxKit

/// Behavior tests for the Core-Animation-backed activity indicators.
///
/// These replaced a `TimelineView(.animation)` spinner and a SwiftUI
/// `repeatForever` pulse that drove the whole window's SwiftUI update cycle
/// from the main thread (~17% main-thread CPU for a single working spinner,
/// measured with `sample` on a Debug build). The CA versions must keep the
/// same visual contract — ten braille glyph frames at 12.5 fps, a 1.1 s ping
/// halo — while installing render-server animations instead of SwiftUI ones.
@MainActor
struct SupermuxAgentActivityIndicatorTests {
    @Test func brailleSpinnerRendersAllTenGlyphFrames() {
        let view = SupermuxBrailleSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.glyphPointSize = 7 * 1.7
        #expect(view.renderedFrameCountForTesting == 10)
        // Monospaced glyphs share one cell so the layer never changes size
        // between frames (a size change would re-enter window layout).
        #expect(view.glyphCellSizeForTesting.width > 0)
        #expect(view.glyphCellSizeForTesting.height > 0)
    }

    @Test func brailleSpinnerReRendersFramesWhenPointSizeChanges() {
        let view = SupermuxBrailleSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.glyphPointSize = 7 * 1.7
        let smallCell = view.glyphCellSizeForTesting
        view.glyphPointSize = 14 * 1.7
        let largeCell = view.glyphCellSizeForTesting
        #expect(largeCell.width > smallCell.width)
        #expect(view.renderedFrameCountForTesting == 10)
    }

    @Test func brailleSpinnerInstallsAndRemovesContentsAnimation() {
        let view = SupermuxBrailleSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.glyphPointSize = 7 * 1.7
        #expect(!view.isAnimationInstalledForTesting)
        view.installAnimationIfNeeded()
        #expect(view.isAnimationInstalledForTesting)
        view.removeAnimation()
        #expect(!view.isAnimationInstalledForTesting)
    }

    @Test func pulsingDotInstallsAndRemovesPingAnimation() {
        let view = SupermuxPulsingDotNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.dotColor = .systemRed
        #expect(!view.isPingAnimationInstalledForTesting)
        view.installAnimationIfNeeded()
        #expect(view.isPingAnimationInstalledForTesting)
        view.removeAnimation()
        #expect(!view.isPingAnimationInstalledForTesting)
    }

    @Test func pulsingDotAppliesColorToDotLayer() {
        let view = SupermuxPulsingDotNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.dotColor = NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        #expect(view.dotColorForTesting != nil)
    }
}

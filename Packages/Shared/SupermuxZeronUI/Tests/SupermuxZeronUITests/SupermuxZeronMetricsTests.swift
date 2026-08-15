import CoreGraphics
import Testing
@testable import SupermuxZeronUI

/// The analytic layout formulas. These are what let a fold tween interpolate
/// two KNOWN heights and a virtualizer skip measuring offscreen rows (plan R4),
/// so a drift here is a clipped row, not a cosmetic nudge.
struct SupermuxZeronMetricsTests {
    typealias Chips = SupermuxZeronMetrics.Chips
    typealias Diff = SupermuxZeronMetrics.Diff
    typealias Composer = SupermuxZeronMetrics.Composer

    @Test("chipsHeight is 2 + 38n, and exactly 0 for an empty group")
    func chipsHeight() {
        #expect(Chips.chipsHeight(0) == 0)
        #expect(Chips.chipsHeight(1) == 40)
        #expect(Chips.chipsHeight(2) == 78)
        #expect(Chips.chipsHeight(3) == 116)
        #expect(Chips.chipsHeight(10) == 382)
        // The 38 pt row less the 30 pt card leaves 4 pt of rail above and below.
        #expect(Chips.rowHeight - Chips.cardHeight == 8)
        #expect(Chips.gap == 0, "rows stack flush so the rail reads continuous")
    }

    @Test("output and stats detail heights are 1 + rows·18 + 12")
    func lineDetailHeight() {
        #expect(Chips.lineDetailHeight(lines: 1) == 31)
        #expect(Chips.lineDetailHeight(lines: 6) == 121)
        // A truncated body adds one counted-tail row.
        #expect(Chips.lineDetailHeight(lines: 24, extraRows: 1) == 463)
    }

    @Test("diff detail height sums notices, hunks and lines")
    func diffDetailHeight() {
        #expect(Diff.detailHeight(notices: 0, hunks: 0, lines: 0) == 9)
        #expect(Diff.detailHeight(notices: 0, hunks: 1, lines: 10) == 247)
        // 1 + 1·24 + 2·28 + 5·21 + 8.
        #expect(Diff.detailHeight(notices: 1, hunks: 2, lines: 5) == 194)
    }

    @Test("gutter width floors at 36 through three digits then grows by 6.6")
    func gutterWidth() {
        for digits in 1 ... 3 {
            #expect(Diff.gutterWidth(digits: digits) == 36, "digits=\(digits)")
        }
        #expect(abs(Diff.gutterWidth(digits: 4) - 40.4) < 1e-9)
        #expect(abs(Diff.gutterWidth(digits: 5) - 47.0) < 1e-9)
        #expect(abs(Diff.gutterWidth(digits: 6) - 53.6) < 1e-9)
        #expect(abs(Diff.gutterWidth(digits: 7) - 60.2) < 1e-9)

        #expect(Diff.digitCount(maxLine: 0) == 1, "a zero/empty file still gets one digit")
        #expect(Diff.digitCount(maxLine: 8) == 1)
        #expect(Diff.digitCount(maxLine: 999) == 3)
        #expect(Diff.digitCount(maxLine: 1000) == 4)

        // Screenshot-verified: max_line 8 puts the first code ink 115 pt in.
        #expect(Diff.codeColumnInset(digits: 1) == 115)
    }

    @Test("diff markers are the exact code points, not ASCII lookalikes")
    func diffMarkers() {
        #expect(Diff.addedMarker == "+")
        #expect(Diff.deletedMarker == "\u{2212}", "MINUS SIGN, not HYPHEN-MINUS")
        #expect(Diff.contextMarker == "\u{00B7}", "MIDDLE DOT")
    }

    @Test("composer auto-grow matches the 04 fixtures")
    func composerAutoGrow() {
        // 1 line → 124, 4 lines → 159, 100 lines → 308.
        #expect(Composer.totalHeight(contentHeight: Composer.contentHeight(lineCount: 1)) == 124)
        #expect(Composer.totalHeight(contentHeight: Composer.contentHeight(lineCount: 4)) == 159)
        #expect(Composer.totalHeight(contentHeight: Composer.contentHeight(lineCount: 100)) == 308)
        // The clamp holds at both ends of the range.
        #expect(Composer.totalHeight(contentHeight: 0) == Composer.minHeight)
        #expect(Composer.totalHeight(contentHeight: 9999) == Composer.maxHeight)
        #expect(Composer.minHeight == Composer.textareaMin + Composer.actionsRowHeight + Composer.pillBorderV)
        #expect(Composer.maxHeight == Composer.textareaMax + Composer.actionsRowHeight + Composer.pillBorderV)
    }

    @Test("the composer flip rule follows composer_flip exactly")
    func composerFlip() {
        // A newline always expands, even when everything else says compact.
        #expect(Composer.shouldExpand(
            expanded: false, textWidth: 0, capacity: 900, hasNewline: true, resizing: false
        ))
        // Frozen during a resize: the current mode survives.
        #expect(Composer.shouldExpand(
            expanded: true, textWidth: 0, capacity: 900, hasNewline: false, resizing: true
        ))
        #expect(!Composer.shouldExpand(
            expanded: false, textWidth: 5000, capacity: 900, hasNewline: false, resizing: true
        ))
        // A too-narrow pill always expands.
        #expect(Composer.shouldExpand(
            expanded: false, textWidth: 0, capacity: 199, hasNewline: false, resizing: false
        ))
        // Compact expands only on actual overflow.
        #expect(!Composer.shouldExpand(
            expanded: false, textWidth: 400, capacity: 400, hasNewline: false, resizing: false
        ))
        #expect(Composer.shouldExpand(
            expanded: false, textWidth: 401, capacity: 400, hasNewline: false, resizing: false
        ))
        // Expanded collapses only when comfortably narrower — 32 pt of slack.
        #expect(Composer.shouldExpand(
            expanded: true, textWidth: 368, capacity: 400, hasNewline: false, resizing: false
        ))
        #expect(!Composer.shouldExpand(
            expanded: true, textWidth: 367.9, capacity: 400, hasNewline: false, resizing: false
        ))
    }

    @Test("last-row bottom pad keeps settled content clear of the fade band")
    func lastRowBottomPad() {
        #expect(SupermuxZeronMetrics.Transcript.lastRowBottomPad(bottomClearance: 100) == 132)
        #expect(
            SupermuxZeronMetrics.Transcript.lastRowBottomPad(
                bottomClearance: 100, runway: 40, safeAreaBottom: 34
            ) == 206
        )
    }

    @Test("transcript column constants")
    func transcriptColumn() {
        typealias T = SupermuxZeronMetrics.Transcript
        #expect(T.maxContentWidth == 736)
        #expect(T.bubbleMaxWidth == 588.8, "736 × 0.8, stored as a constant")
        #expect(T.gutter == 48)
        #expect(T.gapTurn == 14)
        #expect(T.gapBlock == 8)
        #expect(T.mdBlockGap == 12, "§0.3 C6: code wins over mugen-pretext's 14")
        // 38 + 14 + 10.
        #expect(T.row0TopGap == SupermuxZeronMetrics.Theme.titlebarHeight + T.gapTurn + 10)
    }

    // MARK: - Loader math (spec 07 §5.2)

    @Test("pulse phase functions hit their documented endpoints")
    func pulsePhaseFunctions() {
        typealias L = SupermuxZeronMetrics.Loaders
        #expect(abs(L.pulseWave(0.0) - 0) < 1e-9)
        #expect(abs(L.pulseWave(0.5) - 1) < 1e-9)
        #expect(abs(L.pulseWave(1.0) - 0) < 1e-9)
        #expect(abs(L.pulseOpacity(0.0) - 0.08) < 1e-9)
        #expect(abs(L.pulseOpacity(0.5) - 1) < 1e-9)
        #expect(abs(L.pulseScale(0.0) - 0.90) < 1e-9)
        #expect(abs(L.pulseScale(0.5) - 1) < 1e-9)

        // staggeredPhase wraps into [0,1) — rem_euclid, not truncatingRemainder.
        #expect(abs(L.staggeredPhase(0, index: 0, stagger: L.pulseStagger)) < 1e-9)
        #expect(abs(L.staggeredPhase(0, index: 1, stagger: L.pulseStagger) - (1 - L.pulseStagger)) < 1e-9)
        #expect(
            abs(L.staggeredPhase(0.3, index: 2, stagger: L.pulseStagger)
                - L.staggeredPhase(1.3, index: 2, stagger: L.pulseStagger)) < 1e-9
        )
    }

    @Test("gspinOpacity is piecewise linear with a flat rest band")
    func gspinOpacity() {
        typealias L = SupermuxZeronMetrics.Loaders
        #expect(abs(L.gspinOpacity(0.0) - 1.0) < 1e-9, "full at the cycle start")
        #expect(abs(L.gspinOpacity(0.45) - 0.1) < 1e-9, "fully dim")
        #expect(abs(L.gspinOpacity(0.90) - 0.1) < 1e-9, "still in the rest band")
        #expect(abs(L.gspinOpacity(1.0) - 1.0) < 1e-9, "wraps to full")
        let falling = L.gspinOpacity(0.2)
        #expect(falling > 0.1 && falling < 1.0)
        let rising = L.gspinOpacity(0.96)
        #expect(rising > 0.1 && rising < 1.0)
    }

    @Test("the 3x3 wave travels upward and is symmetric about the centre column")
    func matrixWave() {
        typealias L = SupermuxZeronMetrics.Loaders
        // Bottom-centre leads at 0; top corners trail at 0.75.
        #expect(abs(L.matrixCellPhase(row: 2, col: 1) - 0.00) < 1e-9)
        #expect(abs(L.matrixCellPhase(row: 2, col: 0) - 0.25) < 1e-9)
        #expect(abs(L.matrixCellPhase(row: 1, col: 1) - 0.25) < 1e-9)
        #expect(abs(L.matrixCellPhase(row: 1, col: 0) - 0.50) < 1e-9)
        #expect(abs(L.matrixCellPhase(row: 0, col: 1) - 0.50) < 1e-9)
        #expect(abs(L.matrixCellPhase(row: 0, col: 0) - 0.75) < 1e-9)
        for row in 0 ..< 3 {
            #expect(L.matrixCellPhase(row: row, col: 0) == L.matrixCellPhase(row: row, col: 2))
            #expect(L.matrixCellPhase(row: row, col: 1) <= L.matrixCellPhase(row: row, col: 0))
        }
        // 3 cells + 2 half-cell gaps = 4 × cell per side.
        #expect(L.matrixFootprint == 4 * L.matrixCellSize)
        #expect(SupermuxZeronTheme.gradientSpinnerRowTints.count == L.matrixSide)
    }

    // MARK: - Veil (spec 07 §5.7)

    @Test("veil math matches veil.rs")
    func veilMath() {
        typealias V = SupermuxZeronMetrics.Veil
        #expect(V.opacity(0) == 0)
        #expect(V.opacity(1) == 1)
        #expect(abs(V.opacity(0.5) - (1 - pow(0.5, 1.6))) < 1e-12)
        #expect(V.opacity(-1) == 0, "input clamps")
        #expect(V.opacity(2) == 1)

        #expect(V.duration(ema: 10) == 120, "clamps to the 120 ms floor")
        #expect(V.duration(ema: 100) == 300)
        #expect(V.duration(ema: 1000) == 400, "clamps to the 400 ms ceiling")

        #expect(V.boost(chunks: 0) == 1)
        #expect(V.boost(chunks: 2) == 1)
        #expect(abs(V.boost(chunks: 3) - 1.3) < 1e-9)
        #expect(abs(V.boost(chunks: 5) - 1.9) < 1e-9)

        #expect(abs(V.nextEMA(200, gapMS: 100) - 170) < 1e-9)
        #expect(abs(V.nextEMA(200, gapMS: 5000) - 440) < 1e-9, "gap clamps at 1000")
    }

    @Test("spring, own-send and fold constants match transcript.rs")
    func motionConstants() {
        typealias S = SupermuxZeronMetrics.Spring
        #expect(S.damping == 0.7)
        #expect(S.stiffness == 0.05)
        #expect(S.mass == 1.25)
        #expect(abs(S.frameMS - 16.666_666_666_666_668) < 1e-9)
        #expect(S.maxCatchupFrames == 8)
        #expect(S.growthEMA == 0.12)
        #expect(S.chaseMaxLead == 32)
        #expect(S.atBottomPX == 2)
        #expect(S.settleGraceMS == 500)
        #expect(S.glideMaxViewports == 2.5)
        #expect(S.stickThresholdPX == 70)
        #expect(S.jumpThresholdPX == 320)
        #expect(S.overdrawPX == 320)

        typealias O = SupermuxZeronMetrics.OwnSend
        #expect(O.topInset == 48)
        #expect(O.scrollSlack == 2)
        #expect(O.glideRetain == 0.85)
        #expect(O.glideSnapPX == 1)

        #expect(SupermuxZeronMetrics.Fold.tweenWindowMS == 400)
        #expect(SupermuxZeronMetrics.PulseClock.tickInterval == 0.033)
        #expect(SupermuxZeronMetrics.PulseClock.lease == 0.300)
    }
}

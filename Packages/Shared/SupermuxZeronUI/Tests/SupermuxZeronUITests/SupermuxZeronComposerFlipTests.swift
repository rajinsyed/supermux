import CoreGraphics
import Testing
@testable import SupermuxZeronUI

/// The composer's pure decision layer: the flip rule, auto-grow, the attachment
/// wrap model, the morph, and the send-mode machine.
///
/// These are written against spec 04's own in-repo fixtures (`auto_grow_math`,
/// `composer_flip`) so a drift shows up as a failing assertion rather than as a
/// pill that oscillates at the boundary.
struct SupermuxZeronComposerFlipTests {
    typealias Flip = SupermuxZeronComposerFlip
    typealias Metrics = SupermuxZeronMetrics.Composer

    // MARK: - Auto-grow

    @Test("auto_grow_math: 1 line → 124, 4 lines → 159, 100 lines → 308")
    func autoGrowFixtures() {
        #expect(Flip.expandedTotalHeight(contentHeight: Flip.contentHeight(wrappedLineCount: 1)) == 124)
        #expect(Flip.expandedTotalHeight(contentHeight: Flip.contentHeight(wrappedLineCount: 4)) == 159)
        #expect(Flip.expandedTotalHeight(contentHeight: Flip.contentHeight(wrappedLineCount: 100)) == 308)
    }

    @Test("auto-grow clamps to 124…308 at both ends")
    func autoGrowClamps() {
        // 0 lines is treated as 1 — the 76 pt floor is what makes the empty
        // new-chat composer tall.
        #expect(Flip.contentHeight(wrappedLineCount: 0) == Metrics.inputLineHeight)
        #expect(Flip.expandedTotalHeight(contentHeight: 0) == Metrics.minHeight)
        #expect(Flip.expandedTotalHeight(contentHeight: -50) == Metrics.minHeight)
        #expect(Flip.expandedTotalHeight(contentHeight: 10_000) == Metrics.maxHeight)
        // The floor holds through 2 lines (45.5 + 20 = 65.5 < 76) and the first
        // growth appears at 3 (68.25 + 20 = 88.25).
        #expect(Flip.expandedTotalHeight(contentHeight: Flip.contentHeight(wrappedLineCount: 2)) == 124)
        #expect(
            abs(Flip.expandedTotalHeight(contentHeight: Flip.contentHeight(wrappedLineCount: 3)) - 136.25)
                < 1e-9
        )
        // The cap is reached at 11 lines (250.25 + 20 = 270.25 > 260).
        #expect(Flip.expandedTotalHeight(contentHeight: Flip.contentHeight(wrappedLineCount: 11)) == 308)
    }

    @Test("the compact pill is 49 and its inner row is 47")
    func compactGeometry() {
        #expect(Flip.baseHeight(expanded: false, contentHeight: 9_999) == 49)
        #expect(Flip.compactRowHeight == 47)
        // The text box measures off the mode's BASE height, never the animating
        // one: 124 − 2 − 46 = 76.
        #expect(Flip.textBoxHeight(expandedBaseHeight: 124) == 76)
        #expect(Flip.textBoxHeight(expandedBaseHeight: 308) == 260)
        #expect(Flip.maxContentHeight == 240)
    }

    // MARK: - The flip rule

    @Test("a newline always expands, even inside the hysteresis band")
    func newlineAlwaysExpands() {
        #expect(
            Metrics.shouldExpand(
                expanded: false, textWidth: 0, capacity: 600, hasNewline: true, resizing: false
            )
        )
        // ...and even while resizing, which otherwise freezes the mode.
        #expect(
            Metrics.shouldExpand(
                expanded: false, textWidth: 0, capacity: 600, hasNewline: true, resizing: true
            )
        )
    }

    @Test("resizing freezes the current mode")
    func resizingFreezes() {
        #expect(
            !Metrics.shouldExpand(
                expanded: false, textWidth: 9_999, capacity: 300, hasNewline: false, resizing: true
            )
        )
        #expect(
            Metrics.shouldExpand(
                expanded: true, textWidth: 0, capacity: 300, hasNewline: false, resizing: true
            )
        )
    }

    @Test("a too-narrow pill always expands")
    func narrowPillExpands() {
        #expect(
            Metrics.shouldExpand(
                expanded: false, textWidth: 0, capacity: 199.9, hasNewline: false, resizing: false
            )
        )
        #expect(Metrics.minCompactInputWidth == 200)
    }

    @Test("expand and collapse share no boundary — 32 pt of hysteresis")
    func hysteresis() {
        let capacity: CGFloat = 400
        // Compact expands only on actual overflow.
        #expect(
            !Metrics.shouldExpand(
                expanded: false, textWidth: 400, capacity: capacity,
                hasNewline: false, resizing: false
            )
        )
        #expect(
            Metrics.shouldExpand(
                expanded: false, textWidth: 400.1, capacity: capacity,
                hasNewline: false, resizing: false
            )
        )
        // Expanded stays expanded until comfortably narrower than capacity − 32.
        #expect(
            Metrics.shouldExpand(
                expanded: true, textWidth: 368, capacity: capacity,
                hasNewline: false, resizing: false
            )
        )
        #expect(
            !Metrics.shouldExpand(
                expanded: true, textWidth: 367.9, capacity: capacity,
                hasNewline: false, resizing: false
            )
        )
        // The band between the two thresholds is stable in BOTH modes — this is
        // the property that stops the oscillation.
        for width in stride(from: CGFloat(368), through: 400, by: 4) {
            #expect(
                !Metrics.shouldExpand(
                    expanded: false, textWidth: width, capacity: capacity,
                    hasNewline: false, resizing: false
                )
            )
            #expect(
                Metrics.shouldExpand(
                    expanded: true, textWidth: width, capacity: capacity,
                    hasNewline: false, resizing: false
                )
            )
        }
    }

    // MARK: - The reducer

    @Test("a fresh composer starts compact — capacity is infinite before the first measure")
    func startsCompact() {
        var flip = Flip()
        #expect(!flip.expanded)
        #expect(flip.capacity(lastWidth: 0) == .infinity)
        // A wide first pass with no measured width cannot expand it.
        let outcome = flip.evaluate(
            .init(textWidth: 5_000, hasNewline: false, contentHeight: 22.75, lastWidth: 0, layoutEpoch: 1),
            nowMS: 0
        )
        #expect(!outcome.expanded)
        #expect(!outcome.committedFlip)
    }

    @Test("compact learns its capacity as lastWidth − 8, then expands on overflow")
    func learnsCapacity() {
        var flip = Flip()
        // Pass 1: measure a 508 pt input ⇒ capacity 500. Text fits.
        var outcome = flip.evaluate(
            .init(textWidth: 120, hasNewline: false, contentHeight: 22.75, lastWidth: 508, layoutEpoch: 1),
            nowMS: 0
        )
        #expect(!outcome.expanded)
        #expect(flip.compactCapacity == 500)
        // Pass 2: the text overflows ⇒ expand, and the flip epoch advances.
        outcome = flip.evaluate(
            .init(textWidth: 501, hasNewline: false, contentHeight: 22.75, lastWidth: 508, layoutEpoch: 2),
            nowMS: 0
        )
        #expect(outcome.expanded)
        #expect(outcome.committedFlip)
        #expect(flip.flipEpoch == 2)
        // The learned compact capacity survives the flip — this is what the
        // expanded branch measures against.
        #expect(flip.compactCapacity == 500)
    }

    @Test("at most one flip per layout pass")
    func oneFlipPerPass() {
        var flip = Flip()
        _ = flip.evaluate(
            .init(textWidth: 10, hasNewline: false, contentHeight: 22.75, lastWidth: 508, layoutEpoch: 1),
            nowMS: 0
        )
        let expand = flip.evaluate(
            .init(textWidth: 900, hasNewline: false, contentHeight: 22.75, lastWidth: 508, layoutEpoch: 2),
            nowMS: 0
        )
        #expect(expand.committedFlip)
        // Re-running the SAME epoch cannot commit another flip: the measurement
        // that drove the first one is now stale.
        let stale = flip.evaluate(
            .init(textWidth: 10, hasNewline: false, contentHeight: 22.75, lastWidth: 508, layoutEpoch: 2),
            nowMS: 0
        )
        #expect(!stale.committedFlip)
        #expect(stale.expanded)
    }

    @Test("expanded capacity tracks the container delta from its anchor, not the post-flip width")
    func expandedCapacityTracksContainer() {
        var flip = Flip()
        _ = flip.evaluate(
            .init(textWidth: 10, hasNewline: false, contentHeight: 22.75, lastWidth: 508, layoutEpoch: 1),
            nowMS: 0
        )
        _ = flip.evaluate(
            .init(textWidth: 900, hasNewline: false, contentHeight: 45.5, lastWidth: 508, layoutEpoch: 2),
            nowMS: 0
        )
        #expect(flip.expanded)
        // The first pass after expanding anchors on the expanded input width
        // (736, wider than the compact 508 because the expanded box is
        // full-bleed).
        let anchored = flip.evaluate(
            .init(textWidth: 900, hasNewline: false, contentHeight: 45.5, lastWidth: 736, layoutEpoch: 3),
            nowMS: 0
        )
        #expect(flip.expandedAnchor == 736)
        // Capacity is the LEARNED compact value, not 736 − 8.
        #expect(anchored.capacity == 500)
        // Widening the container by 100 shifts capacity by exactly 100.
        let widened = flip.evaluate(
            .init(textWidth: 900, hasNewline: false, contentHeight: 45.5, lastWidth: 836, layoutEpoch: 4),
            nowMS: 200
        )
        #expect(widened.capacity == 600)
    }

    @Test("a same-mode width change freezes the mode for 150 ms")
    func resizeSettle() {
        var flip = Flip()
        _ = flip.evaluate(
            .init(textWidth: 10, hasNewline: false, contentHeight: 22.75, lastWidth: 508, layoutEpoch: 1),
            nowMS: 0
        )
        // The container narrows past the text width at t = 1000.
        let resizing = flip.evaluate(
            .init(textWidth: 400, hasNewline: false, contentHeight: 22.75, lastWidth: 300, layoutEpoch: 2),
            nowMS: 1_000
        )
        #expect(resizing.resizing)
        #expect(!resizing.committedFlip, "the mode is frozen while sizes settle")
        // Still frozen at +149.
        #expect(
            flip.evaluate(
                .init(textWidth: 400, hasNewline: false, contentHeight: 22.75, lastWidth: 300, layoutEpoch: 3),
                nowMS: 1_149
            ).resizing
        )
        // Settled at +150: the overflow finally commits.
        let settled = flip.evaluate(
            .init(textWidth: 400, hasNewline: false, contentHeight: 22.75, lastWidth: 300, layoutEpoch: 4),
            nowMS: 1_150
        )
        #expect(!settled.resizing)
        #expect(settled.expanded)
        #expect(settled.committedFlip)
    }

    @Test("the placeholder cannot trigger the expand flip")
    func placeholderNeverExpands() {
        var flip = Flip()
        _ = flip.evaluate(
            .init(textWidth: 0, hasNewline: false, contentHeight: 22.75, lastWidth: 208, layoutEpoch: 1),
            nowMS: 0
        )
        // textWidth is forced to 0 while the placeholder shows, so even a
        // 200 pt-capacity pill stays compact.
        let outcome = flip.evaluate(
            .init(textWidth: 0, hasNewline: false, contentHeight: 22.75, lastWidth: 208, layoutEpoch: 2),
            nowMS: 0
        )
        #expect(!outcome.expanded)
    }

    @Test("a new chat forces the expanded layout without touching the committed mode")
    func newChatForcesExpanded() {
        #expect(Flip.forcedExpanded(false, newChat: true))
        #expect(Flip.forcedExpanded(false, newChat: false) == false)
        #expect(Flip.forcedExpanded(true, newChat: false))
    }

    // MARK: - Attachments

    @Test("the attachment strip's wrap model is exact")
    func attachmentStripHeight() {
        #expect(Flip.attachmentStripHeight(count: 0, innerWidth: 720) == 0)
        // 720 − 32 = 688 usable ⇒ (688 + 8) / 64 = 10.875 ⇒ 10 per row.
        #expect(Flip.attachmentsPerRow(innerWidth: 720) == 10)
        #expect(Flip.attachmentStripHeight(count: 1, innerWidth: 720) == 68) // 12 + 56
        #expect(Flip.attachmentStripHeight(count: 10, innerWidth: 720) == 68)
        #expect(Flip.attachmentStripHeight(count: 11, innerWidth: 720) == 132) // 12 + 112 + 8
        // A too-narrow pill still fits one per row, never zero.
        #expect(Flip.attachmentsPerRow(innerWidth: 0) == 1)
        #expect(Flip.attachmentRowCount(count: 3, innerWidth: 0) == 3)
        // The rendered rows and the reserved height use the same count.
        for width in [200, 300, 480, 720, 1_200] {
            let perRow = Flip.attachmentsPerRow(innerWidth: CGFloat(width))
            let rows = Flip.attachmentRowCount(count: 7, innerWidth: CGFloat(width))
            #expect(rows == (7 + perRow - 1) / perRow)
        }
    }

    @Test("attachments add their strip in BOTH modes")
    func attachmentsAddInBothModes() {
        #expect(Flip.targetHeight(expanded: false, contentHeight: 22.75) == 49)
        #expect(
            Flip.targetHeight(
                expanded: false, contentHeight: 22.75, attachmentCount: 1, innerWidth: 720
            ) == 117
        )
        #expect(
            Flip.targetHeight(
                expanded: true, contentHeight: 22.75, attachmentCount: 1, innerWidth: 720
            ) == 192
        )
    }

    // MARK: - The morph

    @Test("one committed flip starts exactly one 180 ms morph, and a same-mode pass never restarts it")
    func morphArming() {
        let armed = Flip.stepMorph(
            nil, modeChanged: true, lastHeight: 49, nowMS: 1_000,
            reduceMotion: false, routeSnap: false
        )
        #expect(armed?.from == 49)
        #expect(armed?.startMS == 1_000)
        // Same-mode passes keep the morph until it finishes, then clear it.
        let kept = Flip.stepMorph(
            armed, modeChanged: false, lastHeight: 80, nowMS: 1_100,
            reduceMotion: false, routeSnap: false
        )
        #expect(kept == armed, "a same-mode render can NEVER restart the animation")
        let cleared = Flip.stepMorph(
            armed, modeChanged: false, lastHeight: 124, nowMS: 1_180,
            reduceMotion: false, routeSnap: false
        )
        #expect(cleared == nil)
    }

    @Test("reduced motion, a first paint, and a route snap all snap instead of morphing")
    func morphSnaps() {
        #expect(
            Flip.stepMorph(
                nil, modeChanged: true, lastHeight: 49, nowMS: 0,
                reduceMotion: true, routeSnap: false
            ) == nil
        )
        #expect(
            Flip.stepMorph(
                nil, modeChanged: true, lastHeight: 0, nowMS: 0,
                reduceMotion: false, routeSnap: false
            ) == nil,
            "no measured height yet"
        )
        // A route snap both blocks arming AND kills anything in flight.
        let inFlight = Flip.Morph(from: 49, startMS: 0)
        #expect(
            Flip.stepMorph(
                inFlight, modeChanged: false, lastHeight: 80, nowMS: 50,
                reduceMotion: false, routeSnap: true
            ) == nil
        )
    }

    @Test("the morph lerps from the flip-time height to the LIVE target")
    func morphTracksTarget() {
        let morph = Flip.Morph(from: 49, startMS: 0)
        #expect(morph.height(target: 124, nowMS: 0) == 49)
        #expect(morph.height(target: 124, nowMS: 180) == 124)
        #expect(morph.isDone(nowMS: 180))
        // Mid-flight the target may move (auto-grow); the morph tracks it.
        let mid = morph.height(target: 124, nowMS: 90)
        let midGrown = morph.height(target: 159, nowMS: 90)
        #expect(mid > 49 && mid < 124)
        #expect(midGrown > mid)
        // ease-out is front-loaded: past halfway by the halfway point.
        #expect(morph.progress(nowMS: 90) > 0.5)
    }

    @Test("the morph anchoring helpers all land on the COMMITTED mode's resting value at t=1")
    func morphAnchoring() {
        // The 2.5 pt centering delta decays in both directions...
        #expect(Flip.clusterDY(morph: 0) == 2.5)
        #expect(Flip.clusterDY(morph: 1) == 0)
        // ...but its SIGN is mode-dependent: gpui applies `bottom(-dy)` when
        // expanded and `top(-dy)` when compact, i.e. opposite screen
        // directions. Both still land at 0.
        #expect(Flip.clusterOffsetY(expanded: true, morph: 0) == 2.5)
        #expect(Flip.clusterOffsetY(expanded: false, morph: 0) == -2.5)
        #expect(Flip.clusterOffsetY(expanded: true, morph: 1) == 0)
        #expect(Flip.clusterOffsetY(expanded: false, morph: 1) == 0)

        // The right inset eases toward the COMMITTED mode's resting value, so
        // the two directions are mirror images rather than the same lerp.
        #expect(Flip.clusterInset(expanded: true, morph: 0) == 8, "expanding starts at compact pr-2")
        #expect(Flip.clusterInset(expanded: true, morph: 1) == 12, "and lands on expanded px-3")
        #expect(Flip.clusterInset(expanded: false, morph: 0) == 12, "collapsing starts at px-3")
        #expect(Flip.clusterInset(expanded: false, morph: 1) == 8, "and lands on pr-2")
        // Midway they are the same point, which is why a reversal is seamless.
        #expect(Flip.clusterInset(expanded: true, morph: 0.5) == 10)
        #expect(Flip.clusterInset(expanded: false, morph: 0.5) == 10)

        #expect(Flip.textTopPad(morph: 0) == 12, "the compact py-3 centering inset")
        #expect(Flip.textTopPad(morph: 1) == 16, "pt-4")

        // The collapse glide starts the text HIGH and decays to zero, walking
        // it down onto the compact resting place.
        #expect(Flip.collapseTextGlide(from: 124, morph: 0) == 71)
        #expect(Flip.collapseTextGlide(from: 124, morph: 1) == 0)
        // A short expanded pill never glides at all.
        #expect(Flip.collapseTextGlide(from: 40, morph: 0) == 0)
        #expect(Flip.collapseTextGlide(from: 40, morph: 1) == 0)
    }

    // MARK: - Caret

    @Test("the caret is a 500 ms square wave that starts solid")
    func caretBlink() {
        #expect(Flip.caretVisible(msSinceActivity: 0))
        #expect(Flip.caretVisible(msSinceActivity: 499))
        #expect(!Flip.caretVisible(msSinceActivity: 500))
        #expect(!Flip.caretVisible(msSinceActivity: 999))
        #expect(Flip.caretVisible(msSinceActivity: 1_000))
    }

    // MARK: - Send / stop state machine

    @Test("send / steer / stop selection")
    func sendMode() {
        #expect(SupermuxZeronSendMode.mode(runLive: false, hasText: false) == .send)
        #expect(SupermuxZeronSendMode.mode(runLive: false, hasText: true) == .send)
        #expect(SupermuxZeronSendMode.mode(runLive: true, hasText: true) == .steer)
        #expect(SupermuxZeronSendMode.mode(runLive: true, hasText: false) == .stop)
    }

    @Test("only stop interrupts; send and steer both submit")
    func sendModeAction() {
        #expect(SupermuxZeronSendMode.send.submits)
        #expect(SupermuxZeronSendMode.steer.submits, "steer is VISUALLY identical to send")
        #expect(!SupermuxZeronSendMode.stop.submits)
    }

    @Test("the stop square is neutral geometry, not a red one (§0.3 C11)")
    func stopGeometry() {
        #expect(Metrics.sendDiameter == 28)
        #expect(Metrics.sendGlyph == 14)
        #expect(Metrics.stopSquare == 11)
        #expect(Metrics.stopSquareRadius == 3)
    }
}

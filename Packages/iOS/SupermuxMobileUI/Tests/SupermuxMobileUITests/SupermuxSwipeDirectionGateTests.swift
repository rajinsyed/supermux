import CoreGraphics
@testable import SupermuxMobileUI
import Testing

/// The sidebar swipe rows' direction gate. Regression coverage for the phone
/// swipe that was "really hard to trigger": UIKit asks whether the pan may
/// begin BEFORE the finger has moved (SwiftUI's hosting arbitration probes
/// the recognizer at touch-down), and a gate that refused a zero translation
/// failed the recognizer for the rest of that touch.
@Suite struct SupermuxSwipeDirectionGateTests {
    @Test func doesNotRefuseToBeginBeforeTheFingerMoves() {
        let gate = SupermuxSwipeDirectionGate()
        #expect(gate.mayBegin(translation: .zero))
        // A point of jitter in the wrong direction is not a verdict either.
        #expect(gate.mayBegin(translation: CGPoint(x: 0.3, y: -1.5)))
        #expect(gate.mayBegin(translation: CGPoint(x: 1, y: 2)))
    }

    @Test func refusesToBeginOnVerticalMovement() {
        let gate = SupermuxSwipeDirectionGate()
        #expect(!gate.mayBegin(translation: CGPoint(x: 0, y: -12)))
        #expect(!gate.mayBegin(translation: CGPoint(x: -8, y: -8)))
    }

    @Test func beginsOnDecisivelyHorizontalMovement() {
        let gate = SupermuxSwipeDirectionGate()
        #expect(gate.mayBegin(translation: CGPoint(x: -12, y: 0)))
        #expect(gate.mayBegin(translation: CGPoint(x: -12, y: -6)))
    }

    /// A recognizer that began on the touch-down probe reports its first
    /// samples with almost no movement. Those must stay undecided, not be
    /// latched as "not horizontal" — which would leave the row inert for the
    /// whole swipe that follows.
    @Test func verdictWaitsForEnoughMovementThenLatches() {
        var gate = SupermuxSwipeDirectionGate()
        let atRest = gate.tracks(translation: .zero)
        #expect(!atRest)
        #expect(gate.verdict == nil)
        let barelyMoved = gate.tracks(translation: CGPoint(x: -2, y: 1))
        #expect(!barelyMoved)
        #expect(gate.verdict == nil)
        let moved = gate.tracks(translation: CGPoint(x: -6, y: 1))
        #expect(moved)
        #expect(gate.verdict == true)
        // Latched: a finger arcing downward mid-swipe keeps the row moving.
        let arced = gate.tracks(translation: CGPoint(x: -20, y: 40))
        #expect(arced)
    }

    @Test func verticalVerdictStaysInertForTheWholeTouch() {
        var gate = SupermuxSwipeDirectionGate()
        let vertical = gate.tracks(translation: CGPoint(x: 1, y: 8))
        #expect(!vertical)
        #expect(gate.verdict == false)
        let turnedHorizontal = gate.tracks(translation: CGPoint(x: -60, y: 10))
        #expect(!turnedHorizontal)
        gate.reset()
        #expect(gate.verdict == nil)
        let nextTouch = gate.tracks(translation: CGPoint(x: -60, y: 10))
        #expect(nextTouch)
    }

    @Test func closedRowOnlyOpensTowardItsTray() {
        var ltr = SupermuxSwipeDirectionGate()
        let ltrAwayFromTray = ltr.tracks(translation: CGPoint(x: 12, y: 0))
        #expect(!ltrAwayFromTray)
        var rtl = SupermuxSwipeDirectionGate(opensTowardNegativeX: false)
        let rtlTowardTray = rtl.tracks(translation: CGPoint(x: 12, y: 0))
        #expect(rtlTowardTray)
        let rtlGate = SupermuxSwipeDirectionGate(opensTowardNegativeX: false)
        #expect(!rtlGate.mayBegin(translation: CGPoint(x: -12, y: 0)))
    }

    @Test func openRowMovesEitherWay() {
        var gate = SupermuxSwipeDirectionGate(isRowOpen: true)
        let closing = gate.tracks(translation: CGPoint(x: 12, y: 0))
        #expect(closing)
        gate.reset()
        let reopening = gate.tracks(translation: CGPoint(x: -12, y: 0))
        #expect(reopening)
    }
}

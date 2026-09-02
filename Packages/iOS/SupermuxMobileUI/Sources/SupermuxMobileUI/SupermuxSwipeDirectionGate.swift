import CoreGraphics

/// Decides, once per touch, whether a row's horizontal pan moves the row.
///
/// Pure value logic behind ``SupermuxSidebarSwipeRow``'s pan recognizer, kept
/// out of the recognizer delegate so the gate can be tested without UIKit.
struct SupermuxSwipeDirectionGate: Equatable {
    /// Whether the row currently shows its tray. An open row must also accept
    /// the closing swipe, which runs the other way.
    var isRowOpen = false
    /// Whether a closed row opens on a NEGATIVE x translation (LTR). Without
    /// this the gate would reject the opening drag outright in an RTL layout,
    /// leaving no way to reveal the tray at all.
    var opensTowardNegativeX = true

    /// This touch's direction verdict, latched on the first decisive sample
    /// and held until the touch ends. Re-deciding every frame would abandon
    /// a swipe mid-drag the moment the finger arced downward.
    private(set) var verdict: Bool?

    /// Movement (|x| + |y|) before a sample is decisive enough to judge.
    static let decisionDistance: CGFloat = 4

    /// Whether UIKit may start the recognizer for a touch that has moved by
    /// `translation` so far.
    ///
    /// Never refuses a touch that has not moved enough to judge. Inside a
    /// SwiftUI hosting view the recognizer is asked to begin at touch-down as
    /// well — before any movement, or after a point of jitter — and a
    /// recognizer refused there is failed for the rest of the touch, which
    /// is what made the phone's swipe so hard to start. An undecided begin
    /// is harmless: the row only moves once ``tracks`` has judged the drag
    /// horizontal, and UIKit's own begin (after its ~10pt hysteresis) still
    /// gets refused for a vertical drag.
    func mayBegin(translation: CGPoint) -> Bool {
        !Self.isDecisive(translation) || isHorizontal(translation)
    }

    /// Whether the pan may move the row, deciding once per touch — and only
    /// once the finger has moved far enough to read a direction from.
    mutating func tracks(translation: CGPoint) -> Bool {
        if let verdict { return verdict }
        guard Self.isDecisive(translation) else { return false }
        let decided = isHorizontal(translation)
        verdict = decided
        return decided
    }

    /// Forgets this touch's verdict, ready for the next one.
    mutating func reset() {
        verdict = nil
    }

    /// Whether the finger has moved far enough for direction to mean anything.
    static func isDecisive(_ translation: CGPoint) -> Bool {
        abs(translation.x) + abs(translation.y) >= decisionDistance
    }

    /// Horizontal intent only, with ambiguous diagonals conceded to the
    /// scroll view. Without the bias factor a 45° flick would open rows
    /// during ordinary scrolling.
    func isHorizontal(_ translation: CGPoint) -> Bool {
        guard abs(translation.x) > abs(translation.y) * 1.15 else { return false }
        // A closed row only opens in the reveal direction; an open one
        // moves either way (it can be dragged shut).
        return isRowOpen || (opensTowardNegativeX ? translation.x < 0 : translation.x > 0)
    }
}

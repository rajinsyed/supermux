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

    /// Whether UIKit may start the recognizer for a touch that has moved by
    /// `translation` so far.
    func mayBegin(translation: CGPoint) -> Bool {
        isHorizontal(translation)
    }

    /// Whether the pan may move the row, deciding once per touch.
    mutating func tracks(translation: CGPoint) -> Bool {
        if let verdict { return verdict }
        let decided = isHorizontal(translation)
        verdict = decided
        return decided
    }

    /// Forgets this touch's verdict, ready for the next one.
    mutating func reset() {
        verdict = nil
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

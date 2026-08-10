import Foundation
import Testing

@testable import SupermuxMobileCore

@Suite("SupermuxUnreadBadgeStyle")
struct SupermuxUnreadBadgeStyleTests {
    @Test("a positive count renders as its own numeral")
    func countRendersAsNumeral() {
        #expect(SupermuxUnreadBadgeStyle.displayText(count: 1) == "1")
        #expect(SupermuxUnreadBadgeStyle.displayText(count: 12) == "12")
        #expect(SupermuxUnreadBadgeStyle.displayText(count: 99) == "99")
    }

    @Test("counts past the cap collapse to 99+ instead of widening the badge")
    func overflowCollapses() {
        #expect(SupermuxUnreadBadgeStyle.displayText(count: 100) == "99+")
        #expect(SupermuxUnreadBadgeStyle.displayText(count: 4_000) == "99+")
    }

    @Test("an absent or empty count falls back to the countless dot form")
    func absentCountIsDotForm() {
        // nil is what a phone paired with an upstream cmux Mac sees, and what a
        // group header rolls its members up to.
        #expect(SupermuxUnreadBadgeStyle.displayText(count: nil) == nil)
        #expect(SupermuxUnreadBadgeStyle.displayText(count: 0) == nil)
        // A negative count cannot happen on the wire, but must not render as
        // "-3" if it ever does.
        #expect(SupermuxUnreadBadgeStyle.displayText(count: -3) == nil)
    }

    @Test("one digit stays circular and two digits grow only in width")
    func singleDigitStaysCircular() {
        let style = SupermuxUnreadBadgeStyle(fontSize: 10)
        let single = style.size(count: 7, textWidth: 6)
        #expect(single.width == single.height)

        let double = style.size(count: 42, textWidth: 13)
        #expect(double.width > single.width)
        #expect(double.height == single.height)
    }

    @Test("the dot form is smaller than a counted badge")
    func dotFormIsSmaller() {
        let style = SupermuxUnreadBadgeStyle(fontSize: 10)
        let dot = style.size(count: nil, textWidth: 0)
        #expect(dot.width == dot.height)
        #expect(dot.height < style.height)
    }

    @Test("geometry scales with the font size so both platforms stay in proportion")
    func geometryScalesWithFontSize() {
        let small = SupermuxUnreadBadgeStyle(fontSize: 9)
        let large = SupermuxUnreadBadgeStyle(fontSize: 18)
        #expect(large.height > small.height)
        #expect(large.horizontalPadding > small.horizontalPadding)
        #expect(small.cornerRadius == small.height / 2)
        // The Mac sidebar was tuned around a 9pt numeral in a 16pt circle; the
        // shared ratio has to keep landing there or every Mac row shifts.
        #expect(small.height == 16)
    }

    @Test("a non-positive font size cannot produce a zero-sized badge")
    func degenerateFontSizeIsClamped() {
        let style = SupermuxUnreadBadgeStyle(fontSize: 0)
        #expect(style.height > 0)
        #expect(style.rimWidth > 0)
        #expect(style.dotDiameter > 0)
    }
}

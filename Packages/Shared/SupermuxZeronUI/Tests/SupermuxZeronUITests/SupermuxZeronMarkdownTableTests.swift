import CoreGraphics
import Testing

@testable import SupermuxZeronUI

/// GFM table column geometry — the port of `table_columns` (`render.rs:342`)
/// plus the flex resolution the source CSS describes and SwiftUI has no
/// equivalent for (spec 05 §2.9, §9.2).
@Suite("Zeron markdown tables")
struct SupermuxZeronMarkdownTableTests {
    private typealias Md = SupermuxZeronMetrics.Markdown

    // MARK: - table_columns, against zeron's own fixtures

    @Test("naturals floor at 48 and add 2 × 12 of padding")
    func naturalsFloorAndPadding() {
        // `render.rs:1346-1353` verbatim: content [10, 200] → naturals
        // [72, 224] (48+24, 200+24), minimums [72, 96], min table width 168.
        let geometry = SupermuxZeronTableColumns(contentWidths: [10, 200])
        #expect(geometry.naturals == [72, 224])
        #expect(geometry.minimums == [72, 96])
        #expect(geometry.minTableWidth == 168)
    }

    @Test("a column narrower than its floor keeps its natural width as its floor")
    func minimumIsNeverAboveNatural() {
        // `minimum = min(natural, 96)`, so a 72 pt column floors at 72, NOT 96 —
        // a short column is never forced wider than it needs.
        let geometry = SupermuxZeronTableColumns(contentWidths: [10])
        #expect(geometry.minimums == [72])
    }

    // MARK: - The flex resolution

    @Test("widths are content-PROPORTIONAL, not equal fractions")
    func widthsAreProportionalNotEqual() {
        // `render.rs:1355-1362`: a prose column gets a larger share than short
        // ones. With flex-basis 0 the whole width distributes by grow factor,
        // so the shares are exactly natural / Σnatural.
        let geometry = SupermuxZeronTableColumns(contentWidths: [300, 60, 60])
        #expect(geometry.naturals == [324, 84, 84])

        let widths = geometry.resolved(available: 736)
        // Equal thirds would be 245.33 each — the bug this test exists to catch.
        #expect(widths[0] > 3 * widths[1] * 0.9)
        #expect(abs(widths[1] - widths[2]) < 0.001)
        #expect(abs(widths.reduce(0, +) - 736) < 0.001)

        let total = geometry.naturals.reduce(0, +)
        #expect(abs(widths[0] - 736 * 324 / total) < 0.001)
    }

    @Test("a column that would fall under its floor freezes, and the rest redistribute")
    func floorsFreezeAndRemainderRedistributes() {
        // A wide prose column beside a narrow one: at a tight width the narrow
        // column's proportional share drops below its 96 pt floor, so it pins
        // there and the prose column absorbs what is left. That is what a real
        // flex pass does, and it is why the floor is `min-width` and not a
        // second grow factor.
        let geometry = SupermuxZeronTableColumns(contentWidths: [900, 10])
        // 924 caps at the 96 pt floor; 72 is already under it and keeps itself.
        #expect(geometry.naturals == [924, 72])
        #expect(geometry.minimums == [96, 72])

        let widths = geometry.resolved(available: 300)
        #expect(abs(widths.reduce(0, +) - 300) < 0.001)
        for (width, floor) in zip(widths, geometry.minimums) {
            #expect(width >= floor - 0.001)
        }
    }

    @Test("below the min table width every column sits on its floor and the table scrolls")
    func belowMinimumEveryColumnFloors() {
        let geometry = SupermuxZeronTableColumns(contentWidths: [300, 300, 300])
        #expect(geometry.minTableWidth == 288)
        // The floors no longer fit: the table stops shrinking and scrolls
        // horizontally rather than crushing columns into per-character wrapping.
        #expect(geometry.resolved(available: 100) == geometry.minimums)
        #expect(geometry.resolved(available: 288) == geometry.minimums)
    }

    @Test("resolved widths never fall below the floors at any available width")
    func floorsHoldAtEveryWidth() {
        let geometry = SupermuxZeronTableColumns(contentWidths: [500, 40, 120, 40])
        for available in stride(from: CGFloat(60), through: 1200, by: 20) {
            let widths = geometry.resolved(available: available)
            #expect(widths.count == geometry.naturals.count)
            for (width, floor) in zip(widths, geometry.minimums) {
                #expect(width >= floor - 0.001)
            }
            if available > geometry.minTableWidth {
                #expect(abs(widths.reduce(0, +) - available) < 0.01)
            }
        }
    }

    @Test("an empty table resolves to no columns rather than dividing by zero")
    func emptyTableIsSafe() {
        let geometry = SupermuxZeronTableColumns(contentWidths: [])
        #expect(geometry.minTableWidth == 0)
        #expect(geometry.resolved(available: 736).isEmpty)
    }

    // MARK: - Chrome constants

    @Test("the chrome constants match render.rs")
    func chromeConstants() {
        // `render.rs:40-62`. Uniform padding on all four sides, a 1 pt hairline
        // at 10 % between rows, and the 48/96 pair.
        #expect(Md.tableCellPadding == 12)
        #expect(Md.tableDividerWidth == 1)
        #expect(Md.tableDividerAlpha == 0.10)
        #expect(Md.tableMinColContent == 48)
        #expect(Md.tableMinColWidth == 96)
        // `TABLE_HEADER_WEIGHT = FontWeight::BOLD` = 700, and inline bold is
        // 600 — 700 appears ONLY in a table header.
        #expect(Md.tableHeaderWeight == 700)
        #expect(Md.boldWeight == 600)
    }
}

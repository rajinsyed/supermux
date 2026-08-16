//
//  SupermuxZeronPickerTests.swift
//  SupermuxZeronUITests
//
//  Filtering, ranking, and the ONE MOVING HIGHLIGHT invariant.
//
//  The highlight tests are the important half. "Two highlighted rows" was
//  reported twice against zeron (`pickers.rs:1483–1486`), and the fix is
//  structural rather than cosmetic: hover writes into the shared cursor, and
//  `selected` outranks `active`. A regression would be a per-row `isHovered`
//  fill reappearing at a call site, which these assertions catch as soon as the
//  state stops being the single source of the fill.
//

import CoreGraphics
import Testing

@testable import SupermuxZeronUI

@Suite("Zeron picker filtering and ranking")
struct SupermuxZeronPickerFilterTests {
    private static func row(
        _ id: String,
        _ label: String,
        _ subline: String = "Claude Code",
        favorite: Bool = false
    ) -> SupermuxZeronPickerRow {
        SupermuxZeronPickerRow(id: id, label: label, subline: subline, isFavorite: favorite)
    }

    private static let catalog = [
        row("opus", "Claude Opus 4"),
        row("sonnet", "Claude Sonnet 4"),
        row("haiku", "Claude Haiku 3.5"),
        row("fable", "Fable 5", "Preview"),
    ]

    @Test("match_rank: 0 prefix, 1 substring, nil no match")
    func matchRankLadder() {
        let rank = SupermuxZeronPickerFilter.matchRank
        #expect(rank("cla", "Claude Opus 4") == 0)
        #expect(rank("opus", "Claude Opus 4") == 1)
        #expect(rank("zzz", "Claude Opus 4") == nil)
    }

    @Test("match_rank is case-insensitive and trims the query")
    func matchRankIsCaseInsensitive() {
        let rank = SupermuxZeronPickerFilter.matchRank
        #expect(rank("  CLA  ", "Claude Opus 4") == 0)
        #expect(rank("OPUS", "Claude Opus 4") == 1)
    }

    @Test("An empty query matches everything at rank 1, preserving input order")
    func emptyQueryMatchesEverything() {
        #expect(SupermuxZeronPickerFilter.matchRank(query: "", label: "anything") == 1)
        let filter = SupermuxZeronPickerFilter(query: "")
        #expect(!filter.isSearching)
        #expect(filter.ranked(Self.catalog).map(\.id) == Self.catalog.map(\.id))
    }

    @Test("Prefix matches sort above substring matches")
    func prefixBeatsSubstring() {
        let filter = SupermuxZeronPickerFilter(query: "fa")
        // "Fable 5" is a prefix hit at rank 0; nothing else matches on label.
        #expect(filter.ranked(Self.catalog).map(\.id) == ["fable"])
    }

    @Test("A subline hit ranks below every label hit (+2)")
    func sublineHitsRankBelowLabelHits() {
        let rows = [
            Self.row("a", "Zebra", "Preview harness"),
            Self.row("b", "Preview model", "Claude Code"),
        ]
        // "prev" is a label prefix on b (rank 0) and a subline hit on a
        // (0 + 2 = 2), so b must come first.
        #expect(SupermuxZeronPickerFilter(query: "prev").ranked(rows).map(\.id) == ["b", "a"])
    }

    @Test("Within a rank, starred rows float above unstarred")
    func starsBreakRankTies() {
        let rows = [
            Self.row("plain", "Claude Opus 4"),
            Self.row("starred", "Claude Sonnet 4", favorite: true),
        ]
        // Both are rank-0 prefix hits on "claude"; the star breaks the tie.
        #expect(
            SupermuxZeronPickerFilter(query: "claude").ranked(rows).map(\.id)
                == ["starred", "plain"]
        )
    }

    @Test("Input order breaks the remaining ties")
    func inputOrderBreaksRemainingTies() {
        #expect(
            SupermuxZeronPickerFilter(query: "claude").ranked(Self.catalog).map(\.id)
                == ["opus", "sonnet", "haiku"]
        )
    }

    @Test("Rows with no match are dropped")
    func nonMatchesAreDropped() {
        #expect(SupermuxZeronPickerFilter(query: "qqq").ranked(Self.catalog).isEmpty)
    }

    @Test("A live search removes the rail — the query spans everything")
    func searchingSpansEveryRailTab() {
        var state = SupermuxZeronPickerState(rail: .favorites)
        // Favorites view alone would show nothing, since nothing is starred.
        #expect(state.visibleRows(from: Self.catalog).isEmpty)
        state.setQuery("claude")
        #expect(state.filter.isSearching)
        // The search ignores the rail entirely.
        #expect(state.visibleRows(from: Self.catalog).count == 3)
    }

    @Test("Harness view floats starred rows to the top, preserving catalog order")
    func harnessViewGroupsFavorites() {
        let rows = [
            Self.row("a", "A"),
            Self.row("b", "B", favorite: true),
            Self.row("c", "C"),
            Self.row("d", "D", favorite: true),
        ]
        let state = SupermuxZeronPickerState(rail: .harness)
        #expect(state.visibleRows(from: rows).map(\.id) == ["b", "d", "a", "c"])
    }

    @Test("Favorites view shows only starred rows")
    func favoritesViewFiltersToStars() {
        let rows = [Self.row("a", "A"), Self.row("b", "B", favorite: true)]
        let state = SupermuxZeronPickerState(rail: .favorites)
        #expect(state.visibleRows(from: rows).map(\.id) == ["b"])
    }
}

@Suite("Zeron picker: the single-highlight invariant")
struct SupermuxZeronPickerHighlightTests {
    private static func row(_ id: String, favorite: Bool = false) -> SupermuxZeronPickerRow {
        SupermuxZeronPickerRow(id: id, label: id, subline: "Claude Code", isFavorite: favorite)
    }

    private static let rows = [row("a"), row("b"), row("c")]

    /// The invariant, stated once: **at most one row is ever non-idle per
    /// treatment, and no row wears two.**
    private static func assertSingleHighlight(
        _ state: SupermuxZeronPickerState,
        rows: [SupermuxZeronPickerRow],
        selectedID: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let highlights = rows.indices.map {
            state.highlight(at: $0, rows: rows, selectedID: selectedID)
        }
        #expect(
            highlights.filter { $0 == .selected }.count <= 1,
            "more than one selected row",
            sourceLocation: sourceLocation
        )
        #expect(
            highlights.filter { $0 == .active }.count <= 1,
            "more than one active row",
            sourceLocation: sourceLocation
        )
    }

    @Test("Selected wins over active on the same row — never two washes")
    func selectedOutranksActive() {
        var state = SupermuxZeronPickerState()
        state.hover(1)
        let highlights = Self.rows.indices.map {
            state.highlight(at: $0, rows: Self.rows, selectedID: "b")
        }
        #expect(highlights == [.idle, .selected, .idle])
        // The cursor IS on row 1 — it just does not get to paint there.
        #expect(state.activeIndex == 1)
        Self.assertSingleHighlight(state, rows: Self.rows, selectedID: "b")
    }

    @Test("Hover moves the shared cursor rather than painting its own fill")
    func hoverMovesTheCursor() {
        var state = SupermuxZeronPickerState()
        state.hover(2)
        #expect(state.activeIndex == 2)
        #expect(state.highlight(at: 2, rows: Self.rows, selectedID: nil) == .active)
        #expect(state.highlight(at: 0, rows: Self.rows, selectedID: nil) == .idle)
        Self.assertSingleHighlight(state, rows: Self.rows, selectedID: nil)
    }

    @Test("Hovering a second row moves the cursor off the first")
    func hoveringASecondRowVacatesTheFirst() {
        var state = SupermuxZeronPickerState()
        state.hover(0)
        state.hover(2)
        #expect(state.highlight(at: 0, rows: Self.rows, selectedID: nil) == .idle)
        #expect(state.highlight(at: 2, rows: Self.rows, selectedID: nil) == .active)
        Self.assertSingleHighlight(state, rows: Self.rows, selectedID: nil)
    }

    @Test("Selected and active can coexist on DIFFERENT rows — one each")
    func selectedAndActiveMayDiffer() {
        var state = SupermuxZeronPickerState()
        state.hover(0)
        let highlights = Self.rows.indices.map {
            state.highlight(at: $0, rows: Self.rows, selectedID: "c")
        }
        #expect(highlights == [.active, .idle, .selected])
        Self.assertSingleHighlight(state, rows: Self.rows, selectedID: "c")
    }

    @Test("menu_step wraps at both ends")
    func stepWraps() {
        var state = SupermuxZeronPickerState(activeIndex: 0)
        state.step(-1, count: 3)
        #expect(state.activeIndex == 2)
        state.step(1, count: 3)
        #expect(state.activeIndex == 0)
        state.step(2, count: 3)
        #expect(state.activeIndex == 2)
    }

    @Test("An empty list parks the cursor at 0 rather than going out of range")
    func stepOnEmptyList() {
        var state = SupermuxZeronPickerState(activeIndex: 5)
        state.step(1, count: 0)
        #expect(state.activeIndex == 0)
        #expect(state.highlight(at: 0, rows: [], selectedID: nil) == .idle)
    }

    @Test("Opening anchors the cursor on the SELECTED row, never row 0")
    func openAnchorsOnSelection() {
        var state = SupermuxZeronPickerState()
        state.open(rows: Self.rows, selectedID: "c", hasFavorites: false, isLocked: false)
        #expect(state.rail == .harness)
        #expect(state.activeIndex == 2)
        Self.assertSingleHighlight(state, rows: Self.rows, selectedID: "c")
    }

    @Test("Opening primes the rail BEFORE anchoring — the visible rows depend on it")
    func openPrimesTheRailFirst() {
        let rows = [Self.row("a"), Self.row("b", favorite: true), Self.row("c")]
        var state = SupermuxZeronPickerState()
        state.open(rows: rows, selectedID: "b", hasFavorites: true, isLocked: false)
        #expect(state.rail == .favorites)
        // In the favorites view only "b" is visible, so the anchor is index 0 —
        // which is index 1 in the unfiltered catalog. Anchoring before priming
        // would have produced 1 and highlighted nothing.
        #expect(state.activeIndex == 0)
        #expect(state.visibleRows(from: rows).map(\.id) == ["b"])
    }

    @Test("A locked session stays on its own harness tab even with stars")
    func lockedSessionStaysOnHarness() {
        let rows = [Self.row("a", favorite: true), Self.row("b")]
        var state = SupermuxZeronPickerState()
        state.open(rows: rows, selectedID: "b", hasFavorites: true, isLocked: true)
        #expect(state.rail == .harness)
    }

    @Test("Opening clears a stale query")
    func openClearsTheQuery() {
        var state = SupermuxZeronPickerState(query: "sonnet")
        state.open(rows: Self.rows, selectedID: "a", hasFavorites: false, isLocked: false)
        #expect(state.filter.query.isEmpty)
        #expect(!state.filter.isSearching)
    }

    @Test("Typing resets the cursor to the top of the fresh results")
    func typingResetsTheCursor() {
        var state = SupermuxZeronPickerState(activeIndex: 2)
        state.setQuery("a")
        #expect(state.activeIndex == 0)
    }

    @Test("An unchanged query does not disturb the cursor")
    func repeatedQueryDoesNotReset() {
        var state = SupermuxZeronPickerState(query: "a", activeIndex: 2)
        state.setQuery("a")
        #expect(state.activeIndex == 2)
    }

    @Test("Starring re-homes the cursor onto the SELECTED row, not the starred one")
    func favoriteToggleRehomesToSelection() {
        // "c" is selected; starring "a" floats it to the top and reorders the
        // list. The cursor must follow the SELECTION, or its wash ends up
        // beside the selected row's ring — the "two highlighted rows" report.
        let after = [Self.row("a", favorite: true), Self.row("b"), Self.row("c")]
        var state = SupermuxZeronPickerState(activeIndex: 0)
        state.rehomeAfterFavoriteToggle(rows: after, selectedID: "c")
        let visible = state.visibleRows(from: after)
        #expect(visible.map(\.id) == ["a", "b", "c"])
        #expect(state.activeIndex == 2)
        #expect(state.highlight(at: 2, rows: visible, selectedID: "c") == .selected)
        #expect(state.highlight(at: 0, rows: visible, selectedID: "c") == .idle)
        Self.assertSingleHighlight(state, rows: visible, selectedID: "c")
    }

    @Test("Switching rail tabs re-anchors the cursor onto the selection")
    func railSwitchReanchors() {
        let rows = [Self.row("a"), Self.row("b", favorite: true), Self.row("c")]
        var state = SupermuxZeronPickerState(rail: .harness, activeIndex: 2)
        state.selectRail(.favorites, rows: rows, selectedID: "b")
        #expect(state.rail == .favorites)
        #expect(state.activeIndex == 0)
    }

    @Test("A selection outside the current view anchors at 0, not out of range")
    func selectionOutsideTheViewAnchorsAtZero() {
        let rows = [Self.row("a"), Self.row("b", favorite: true)]
        var state = SupermuxZeronPickerState(rail: .harness)
        // Favorites shows only "b"; "a" is not in it.
        state.selectRail(.favorites, rows: rows, selectedID: "a")
        #expect(state.activeIndex == 0)
    }

    @Test("An out-of-range index is idle, never a crash")
    func outOfRangeIndexIsIdle() {
        let state = SupermuxZeronPickerState(activeIndex: 99)
        #expect(state.highlight(at: 99, rows: Self.rows, selectedID: nil) == .idle)
        #expect(state.highlight(at: -1, rows: Self.rows, selectedID: nil) == .idle)
    }
}

@Suite("Zeron picker: menu anchoring and the press guard")
@MainActor
struct SupermuxZeronAnchoredMenuTests {
    /// `snap_to_window_with_margin(8)` clamps to the **window**, not the screen.
    @Test("A card overflowing the window's right edge is pulled back by the margin")
    func clampPullsBackFromTheRightEdge() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 800)
        // 360 wide starting at 60 ends at 420 — 20 past the edge, so it must
        // move left far enough to leave the 8 pt margin: to 400 − 8 − 360 = 32.
        let card = CGRect(x: 60, y: 100, width: 360, height: 346)
        let fix = SupermuxZeronWindowClamp.correction(
            for: card, in: window, current: .zero, margin: 8
        )
        #expect(fix.width == -28)
        #expect(fix.height == 0)
    }

    @Test("A card overflowing the TOP is pushed down — the menu opens upward")
    func clampPushesDownFromTheTop() {
        let window = CGRect(x: 0, y: 0, width: 900, height: 400)
        // Anchored above a chip near the top of a short window.
        let card = CGRect(x: 100, y: -20, width: 360, height: 346)
        let fix = SupermuxZeronWindowClamp.correction(
            for: card, in: window, current: .zero, margin: 8
        )
        #expect(fix.height == 28)
    }

    @Test("The correction is idempotent — a second pass does not compound it")
    func clampIsIdempotent() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 800)
        let natural = CGRect(x: 60, y: 100, width: 360, height: 346)
        let first = SupermuxZeronWindowClamp.correction(
            for: natural, in: window, current: .zero, margin: 8
        )
        // The next frame measures the ALREADY-corrected frame.
        let corrected = natural.offsetBy(dx: first.width, dy: first.height)
        let second = SupermuxZeronWindowClamp.correction(
            for: corrected, in: window, current: first, margin: 8
        )
        #expect(second == first)
    }

    @Test("A card that fits is left exactly where it was anchored")
    func clampLeavesAFittingCardAlone() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let card = CGRect(x: 400, y: 300, width: 360, height: 346)
        let fix = SupermuxZeronWindowClamp.correction(
            for: card, in: window, current: .zero, margin: 8
        )
        #expect(fix == .zero)
    }

    @Test("A card wider than the window pins to the LEADING margin, not the trailing one")
    func clampPrefersTheNearEdgeWhenItCannotFit() {
        let window = CGRect(x: 0, y: 0, width: 300, height: 800)
        let card = CGRect(x: 20, y: 100, width: 360, height: 346)
        let fix = SupermuxZeronWindowClamp.correction(
            for: card, in: window, current: .zero, margin: 8
        )
        // Ends up at x = 8: visible from the leading edge rather than running
        // off it, which is the readable failure mode.
        #expect(fix.width == -12)
    }

    /// `note_trigger_press` / `take_press_was_open` (`popover.rs:143–168`).
    @Test("A press while THIS menu was open makes the click close, not reopen")
    func pressWhileOpenClosesOnClick() {
        let guardian = SupermuxZeronMenuPressGuard()
        guardian.notePress(identity: "model", isMounted: true)
        #expect(guardian.takePressWasOpen(identity: "model"))
    }

    @Test("The note is CONSUMED — a second read is false")
    func theNoteIsConsumed() {
        let guardian = SupermuxZeronMenuPressGuard()
        guardian.notePress(identity: "model", isMounted: true)
        _ = guardian.takePressWasOpen(identity: "model")
        #expect(!guardian.takePressWasOpen(identity: "model"))
    }

    @Test("A press on a DIFFERENT trigger does not count — that click switches menus")
    func aPressOnAnotherTriggerSwitchesRatherThanSwallows() {
        let guardian = SupermuxZeronMenuPressGuard()
        // The traits menu was open; the press landed on the model chip.
        guardian.notePress(identity: "traits", isMounted: true)
        #expect(!guardian.takePressWasOpen(identity: "model"))
    }

    @Test("A fresh open leaves no note, so the click opens")
    func aFreshOpenLeavesNoNote() {
        let guardian = SupermuxZeronMenuPressGuard()
        guardian.notePress(identity: "model", isMounted: false)
        #expect(!guardian.takePressWasOpen(identity: "model"))
    }
}

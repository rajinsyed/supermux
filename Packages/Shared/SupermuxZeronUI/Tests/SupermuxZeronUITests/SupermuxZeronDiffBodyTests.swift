//
//  SupermuxZeronDiffBodyTests.swift
//  SupermuxZeronUITests
//
//  The inline diff body, built from a REAL Claude Code `structuredPatch`
//  payload rather than a hand-assembled model, so the parse → row-model →
//  rendered-frame path is covered end to end.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import SupermuxClaudeHarness
@testable import SupermuxZeronUI

@Suite("Zeron diff body")
@MainActor
struct SupermuxZeronDiffBodyTests {
    private typealias DiffM = SupermuxZeronMetrics.Diff

    // MARK: - Fixture

    /// The `s4-details.png` edit result, in the shape Claude Code actually
    /// sends: `tool_use_result.structuredPatch` with `oldStart`/`newStart` and
    /// raw `+`/`-`/space-prefixed lines.
    private static let resolveEdit = ClaudeJSONValue.object([
        "structuredPatch": .array([
            .object([
                "oldStart": .number(2),
                "oldLines": .number(7),
                "newStart": .number(2),
                "newLines": .number(6),
                "lines": .array([
                    .string(" "),
                    .string(" /// Locate the agent binary."),
                    .string(" fn resolve(exe: &str) -> Option<PathBuf> {"),
                    .string("-        std::env::var_os(\"PATH\")"),
                    .string("-            .map(PathBuf::from)"),
                    .string("-            .filter(|p| p.exists())"),
                    .string("+        let dirs = std::env::split_paths(&std::env::var_os(\"PATH\")?);"),
                    .string("+        dirs.map(|d| d.join(exe)).find(|p| p.exists())"),
                    .string(" }"),
                ]),
            ]),
        ]),
    ])

    private func fixtureDiff() throws -> SupermuxHarnessDiff {
        try #require(SupermuxHarnessDiff.from(toolUseResult: Self.resolveEdit))
    }

    // MARK: - Construction from a real payload

    @Test("A structuredPatch becomes one hunk with dual 1-based line numbers")
    func rowsAreBuiltFromTheRealPayload() throws {
        let diff = try fixtureDiff()
        #expect(diff.hunks.count == 1)
        let hunk = try #require(diff.hunks.first)
        #expect(hunk.lines.count == 9)
        #expect(hunk.additions == 2)
        #expect(hunk.deletions == 3)

        // Context lines advance BOTH counters; a deletion advances only old, an
        // addition only new — which is what makes the two gutters disagree.
        let kinds = hunk.lines.map(\.kind)
        #expect(kinds == [
            .context, .context, .context,
            .deletion, .deletion, .deletion,
            .addition, .addition,
            .context,
        ])
        #expect(hunk.lines[2].oldNumber == 4)
        #expect(hunk.lines[2].newNumber == 4)
        // The first deletion is old line 5 with NO new number.
        #expect(hunk.lines[3].oldNumber == 5)
        #expect(hunk.lines[3].newNumber == nil)
        // The first addition is new line 5 with NO old number.
        #expect(hunk.lines[6].oldNumber == nil)
        #expect(hunk.lines[6].newNumber == 5)
        // The trailing context resumes at old 8 / new 7 — the screenshot's
        // last row exactly.
        #expect(hunk.lines[8].oldNumber == 8)
        #expect(hunk.lines[8].newNumber == 7)

        // The marker prefix is stripped; indentation is preserved verbatim.
        #expect(hunk.lines[3].text == "        std::env::var_os(\"PATH\")")
    }

    @Test("The hunk header is synthesized as @@ -old,len +new,len @@")
    func hunkHeaderText() throws {
        let hunk = try #require(fixtureDiff().hunks.first)
        // 3 context + 3 deletions + 1 trailing context = 7 old lines;
        // 3 + 2 + 1 = 6 new lines. The screenshot reads "@@ -2,7 +2,6 @@".
        #expect(SupermuxZeronDiffHunkHeaderRow.header(for: hunk) == "@@ -2,7 +2,6 @@")
    }

    // MARK: - Analytic vs rendered

    @Test("The body height is notices×24 + hunks×28 + lines×21 + 8")
    func bodyHeightMatchesTheFormula() throws {
        let diff = try fixtureDiff()
        // 1×28 + 9×21 + 8 = 225; the detail adds its 1 pt separator → 226.
        #expect(SupermuxZeronDiffBody.bodyHeight(of: diff) == 225)
        #expect(SupermuxHarnessChipDetail.diff(diff).height == 226)

        let view = SupermuxZeronDiffBody(diff: diff, theme: .dark)
        #expect(
            SupermuxZeronRenderProbe.height(of: view).matchesAnalytic(225),
            "every row is a hard `.frame(height:)`, so nothing can grow"
        )
    }

    @Test("A notice adds exactly one 24 pt row, at the TOP of the body")
    func noticesAddTwentyFour() throws {
        let base = try fixtureDiff()
        let withNotice = SupermuxHarnessDiff(hunks: base.hunks, notices: ["New file"])
        #expect(
            SupermuxZeronDiffBody.bodyHeight(of: withNotice)
                == SupermuxZeronDiffBody.bodyHeight(of: base) + DiffM.noticeHeight
        )

        let view = SupermuxZeronDiffBody(diff: withNotice, theme: .dark)
        #expect(
            SupermuxZeronRenderProbe.height(of: view)
                .matchesAnalytic(SupermuxZeronDiffBody.bodyHeight(of: withNotice)),
            "the notice row is 24 pt, above every hunk"
        )
    }

    // MARK: - The 600-line cap

    @Test("A diff past 600 lines truncates mid-hunk and appends the notice")
    func sixHundredLineCap() {
        let lines = (1 ... 1_000).map { SupermuxHarnessDiff.Line(
            id: "l\($0)", kind: .addition, oldNumber: nil, newNumber: $0, text: "line \($0)"
        ) }
        let diff = SupermuxHarnessDiff(hunks: [
            SupermuxHarnessDiff.Hunk(
                id: "h", oldStart: 1, newStart: 1, lines: lines, isSynthetic: false
            ),
        ])
        #expect(diff.lineCount == 1_000)

        let capped = diff.truncated(to: SupermuxZeronMetrics.Chips.diffMaxLines)
        #expect(capped.lineCount == 600)
        #expect(capped.notices.count == 1)
        #expect(
            capped.notices[0]
                == "Diff truncated \u{2014} showing first 600 of 1000 lines"
        )
        // The notice is counted in the analytic height, at 24 pt.
        // Spelled out rather than inlined: a four-term literal expression
        // compared against a CGFloat sends Swift's type checker exponential.
        let expected: CGFloat = 24 + 28 + 600 * 21 + 8
        #expect(SupermuxZeronDiffBody.bodyHeight(of: capped) == expected)
    }

    @Test("A short diff is untouched — no notice, no re-gutter")
    func shortDiffIsUntouched() throws {
        let diff = try fixtureDiff()
        #expect(diff.truncated(to: 600) == diff)
        #expect(diff.notices.isEmpty)
    }

    // MARK: - Gutter width

    @Test("The gutter refits the largest line number that actually renders")
    func gutterRefitsPostTruncation() throws {
        // The fixture's largest number is 8, so the 36 pt floor wins and the
        // first code ink lands 115 pt in — the screenshot's measured value.
        let diff = try fixtureDiff()
        #expect(SupermuxZeronDiffBody.maxLine(diff) == 8)
        #expect(DiffM.gutterWidth(digits: DiffM.digitCount(maxLine: 8)) == 36)
        #expect(DiffM.codeColumnInset(digits: 1) == 115)

        // Truncating a 4-digit file back under 1000 must SHRINK the gutter,
        // which is why max line is recomputed from the survivors rather than
        // carried on the model.
        let long = SupermuxHarnessDiff(hunks: [
            SupermuxHarnessDiff.Hunk(
                id: "h",
                oldStart: 1,
                newStart: 1,
                lines: (1 ... 1_200).map {
                    SupermuxHarnessDiff.Line(
                        id: "l\($0)", kind: .context, oldNumber: $0, newNumber: $0, text: "x"
                    )
                },
                isSynthetic: false
            ),
        ])
        #expect(SupermuxZeronDiffBody.maxLine(long) == 1_200)
        #expect(DiffM.gutterWidth(digits: 4) == 40.4)
        let capped = long.truncated(to: 600)
        #expect(SupermuxZeronDiffBody.maxLine(capped) == 600)
        #expect(DiffM.gutterWidth(digits: DiffM.digitCount(maxLine: 600)) == 36)
    }

    // MARK: - Markers

    @Test("Markers are the exact code points, not ASCII lookalikes")
    func markerCodePoints() {
        #expect(DiffM.addedMarker == "+")
        #expect(DiffM.addedMarker.unicodeScalars.map(\.value) == [0x2B])
        // U+2212 MINUS SIGN — a hyphen would be visibly shorter and lower.
        #expect(DiffM.deletedMarker.unicodeScalars.map(\.value) == [0x2212])
        // U+00B7 MIDDLE DOT — not a period, not a bullet.
        #expect(DiffM.contextMarker.unicodeScalars.map(\.value) == [0x00B7])
    }

    @Test("Column widths and alphas match changes.rs")
    func columnGeometryAndAlphas() {
        #expect(DiffM.accentBarWidth == 3)
        #expect(DiffM.markerWidth == 28)
        #expect(DiffM.lineHeight == 21)
        #expect(DiffM.hunkHeaderHeight == 28)
        #expect(DiffM.noticeHeight == 24)
        #expect(DiffM.bodyBottomPad == 8)

        #expect(DiffM.rowWashAlpha == 0.055)
        #expect(DiffM.accentBarAlpha == 0.55)
        #expect(DiffM.matchingNumberAlpha == 0.9)
        #expect(DiffM.faintNumberAlpha == 0.8)
        #expect(DiffM.contextMarkerAlpha == 0.5)
        #expect(DiffM.codePlainAlpha == 0.92)
    }

    // MARK: - Highlights

    @Test("Highlight spans pick the side that owns the line")
    func highlightSideSelection() throws {
        let hunk = try #require(fixtureDiff().hunks.first)
        let keyword = SupermuxZeronDiffHighlights.Span(start: 0, end: 2, kind: .keyword)
        let string = SupermuxZeronDiffHighlights.Span(start: 0, end: 3, kind: .string)
        let highlights = SupermuxZeronDiffHighlights(
            old: [5: [keyword]],
            new: [5: [string], 4: [keyword]]
        )

        // A deletion reads OLD at its old number.
        #expect(highlights.spans(for: hunk.lines[3]) == [keyword])
        // An addition reads NEW at its new number.
        #expect(highlights.spans(for: hunk.lines[6]) == [string])
        // Context prefers NEW when a new document exists.
        #expect(highlights.spans(for: hunk.lines[2]) == [keyword])

        // …and having CHOSEN the new side, a miss there paints plain rather
        // than falling back to the old document. `source_ref` picks the side
        // first and then reads it (changes.rs:115); a fallback would colour the
        // line against a document whose text at that number is a different line.
        let newOnlyMiss = SupermuxZeronDiffHighlights(old: [4: [keyword]], new: [99: [string]])
        #expect(newOnlyMiss.spans(for: hunk.lines[2]).isEmpty)
        // With no new document at all, context falls back to old — that IS the
        // spec'd path (`filter(|_| self.new.is_some())`).
        let oldOnly = SupermuxZeronDiffHighlights(old: [4: [keyword]], new: [:])
        #expect(oldOnly.spans(for: hunk.lines[2]) == [keyword])
    }

    @Test("Highlighting never changes layout — plain and colored measure the same")
    func highlightingIsPaintOnly() throws {
        let diff = try fixtureDiff()
        let highlights = SupermuxZeronDiffHighlights(
            old: [5: [.init(start: 8, end: 11, kind: .keyword)]],
            new: [5: [.init(start: 8, end: 11, kind: .keyword)]]
        )
        let plain = SupermuxZeronDiffBody(diff: diff, theme: .dark)
        let colored = SupermuxZeronDiffBody(diff: diff, theme: .dark, highlights: highlights)

        guard
            let plainHeight = SupermuxZeronRenderProbe.height(of: plain),
            let coloredHeight = SupermuxZeronRenderProbe.height(of: colored)
        else { return }
        #expect(plainHeight == coloredHeight, "a recolor must cause NO relayout (plan R9)")
    }

    @Test("A malformed byte offset is dropped, never trapped on")
    func malformedSpansAreDropped() throws {
        let hunk = try #require(fixtureDiff().hunks.first)
        // Past the end of the line, and a reversed range.
        let bad = SupermuxZeronDiffHighlights(new: [5: [
            .init(start: 0, end: 10_000, kind: .keyword),
            .init(start: 9, end: 3, kind: .string),
            .init(start: -4, end: 2, kind: .number),
        ]])
        let row = SupermuxZeronDiffLineRow(
            line: hunk.lines[6],
            theme: .dark,
            gutterWidth: 36,
            spans: bad.spans(for: hunk.lines[6])
        )
        // gpui tolerates a bad offset; `AttributedString` would trap on one, so
        // the renderer must skip rather than crash on model-generated input.
        #expect(
            SupermuxZeronRenderProbe.height(of: row).matchesAnalytic(DiffM.lineHeight),
            "a row with unusable spans still paints at exactly 21 pt"
        )
    }
}

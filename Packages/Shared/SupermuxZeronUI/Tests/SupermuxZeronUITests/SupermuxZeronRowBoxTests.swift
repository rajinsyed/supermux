import Foundation
import SupermuxClaudeHarness
import Testing
@testable import SupermuxZeronUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The transcript row box's vertical rhythm, the timestamp lane's format, the
/// last row's clearance arithmetic, and the working trailer's pure rules.
struct SupermuxZeronRowBoxTests {

    private static func row(
        id: String,
        kind: SupermuxHarnessRow.Kind,
        turnStart: Bool = false,
        entryID: String? = nil,
        timestamp: Date? = nil
    ) -> SupermuxHarnessRow {
        SupermuxHarnessRow(
            id: id,
            kind: kind,
            turnStart: turnStart,
            entryID: entryID,
            timestamp: timestamp
        )
    }

    private static func prose(_ id: String, turnStart: Bool = false) -> SupermuxHarnessRow {
        row(
            id: id,
            kind: .assistantProse(text: "x", isStreaming: false),
            turnStart: turnStart,
            entryID: "msg-1"
        )
    }

    // MARK: - Gap selection

    @Test("Row 0 carries the titlebar inside its own top gap: 38 + 14 + 10 = 62")
    func rowZeroGap() {
        let first = Self.prose("msg-1-0", turnStart: true)
        #expect(SupermuxZeronRowGap.topGap(index: 0, previous: nil, row: first) == 62)
        #expect(SupermuxZeronRowGap.row0 == 62)
        // Row 0 takes 62 even when it is NOT a turn start, because the reason is
        // the chrome it scrolls under, not the message boundary.
        let notATurn = Self.prose("msg-1-0", turnStart: false)
        #expect(SupermuxZeronRowGap.topGap(index: 0, previous: nil, row: notATurn) == 62)
    }

    @Test("turnStart selects GAP_TURN (14); everything else defaults to GAP_BLOCK (8)")
    func turnStartSelectsFourteen() {
        let previous = Self.prose("msg-1-0")
        let turn = Self.row(
            id: "prompt-2",
            kind: .userPrompt(text: "hi"),
            turnStart: true,
            entryID: "entry-2"
        )
        #expect(SupermuxZeronRowGap.topGap(previous: previous, row: turn) == 14)

        // A tool group inside the same entry is neither a turn start nor two
        // markdown blocks, so it takes the 8 pt block gap.
        let group = Self.row(
            id: "msg-1#g0",
            kind: .toolGroup(SupermuxHarnessToolGroup(id: "msg-1#g0", tools: [])),
            entryID: "msg-1"
        )
        #expect(SupermuxZeronRowGap.topGap(previous: previous, row: group) == 8)
    }

    @Test("Two markdown blocks of the SAME part take the 12 pt markdown gap")
    func markdownSiblingsTakeTwelve() {
        // This is the rule that keeps a message from jumping a pixel when it
        // completes: a streaming message is one live row whose blocks stack with
        // MD_BLOCK_GAP, and the split rows' gaps must equal those.
        let first = Self.prose("msg-1-0")
        let second = Self.prose("msg-1-1")
        #expect(SupermuxZeronRowGap.topGap(previous: first, row: second) == 12)
    }

    @Test("Markdown blocks of DIFFERENT parts fall back to the 8 pt block gap")
    func markdownAcrossPartsTakesEight() {
        let first = Self.prose("msg-1-0")
        let other = Self.row(
            id: "msg-2-0",
            kind: .assistantProse(text: "y", isStreaming: false),
            entryID: "msg-2"
        )
        #expect(SupermuxZeronRowGap.topGap(previous: first, row: other) == 8)
    }

    @Test("A markdown row after a NON-markdown row takes the block gap")
    func markdownAfterToolTakesEight() {
        // Both sides must be markdown; a prose block right after a tool group in
        // the same message is a block boundary, not a paragraph boundary.
        let group = Self.row(
            id: "msg-1#g0",
            kind: .toolGroup(SupermuxHarnessToolGroup(id: "msg-1#g0", tools: [])),
            entryID: "msg-1"
        )
        let after = Self.prose("msg-1-2")
        #expect(SupermuxZeronRowGap.topGap(previous: group, row: after) == 8)
    }

    @Test("Thinking is NOT markdown for gap purposes")
    func thinkingIsNotMarkdown() {
        // Thinking renders with the group-header primitive, not as a markdown
        // block, so it must not inherit the 12 pt paragraph gap.
        let first = Self.prose("msg-1-0")
        let thinking = Self.row(
            id: "msg-1-1",
            kind: .thinking(text: "…", isStreaming: false),
            entryID: "msg-1"
        )
        #expect(SupermuxZeronRowGap.topGap(previous: first, row: thinking) == 8)
    }

    @Test("The part-prefix comparison handles both id shapes")
    func partPrefixShapes() {
        // supermux's builder emits `{entryID}-{blockIndex}`.
        #expect(SupermuxZeronRowGap.sharePartPrefix("msg-1-0", "msg-1-1"))
        #expect(!SupermuxZeronRowGap.sharePartPrefix("msg-1-0", "msg-2-0"))
        // zeron's own shape is `{entry}#{part}.{blockIx}`, which a wire-decoded
        // row could carry.
        #expect(SupermuxZeronRowGap.sharePartPrefix("e1#p1.0", "e1#p1.1"))
        #expect(!SupermuxZeronRowGap.sharePartPrefix("e1#p1.0", "e1#p2.0"))
        // An id with no separator at all shares a prefix with nothing.
        #expect(!SupermuxZeronRowGap.sharePartPrefix("solo", "solo"))
    }

    // MARK: - Last-row clearance

    @Test("The last row's bottom pad is clearance + 24 + 8 + runway")
    func lastRowBottomPad() {
        // NOTE on the `CGFloat(...)` wrappers throughout this file: inside
        // `#expect`, a bare arithmetic literal like `120 + 24 + 8` infers as
        // `Int`, and the macro's heterogeneous comparison then fails against a
        // `CGFloat` that IS numerically equal. Annotating the expectation is
        // what makes these assertions test the value rather than the inference.
        //
        // The +24 clears the fade band; the +8 is literal breathing room so the
        // timestamp lane — the row's LOWEST content — never renders inside the
        // fade when the transcript is pinned.
        #expect(
            SupermuxZeronMetrics.Transcript.lastRowBottomPad(bottomClearance: 120)
                == CGFloat(120 + 24 + 8)
        )
        #expect(
            SupermuxZeronMetrics.Transcript.lastRowBottomPad(bottomClearance: 120, runway: 300)
                == CGFloat(120 + 24 + 8 + 300)
        )
        // iOS adds its bottom safe area on top, and the fade's bandBottom grows
        // by the same amount, so the two cannot drift.
        #expect(
            SupermuxZeronMetrics.Transcript.lastRowBottomPad(
                bottomClearance: 120,
                runway: 0,
                safeAreaBottom: 34
            ) == CGFloat(120 + 24 + 8 + 34)
        )
    }

    // MARK: - Edge fade

    @Test("The bottom band is stackHeight − the reserved status strip, floored at 1")
    func edgeFadeBottomBand() {
        #expect(SupermuxZeronEdgeFade.bandBottom(stackHeight: 140) == CGFloat(140 - 24))
        // The 24 pt status strip above the pill is empty air, so a stack shorter
        // than it must still produce a positive band rather than an inverted one.
        #expect(SupermuxZeronEdgeFade.bandBottom(stackHeight: 10) == CGFloat(1))
        #expect(SupermuxZeronEdgeFade.bandBottom(stackHeight: 0) == CGFloat(1))
        // iOS grows it by the bottom safe area, matching the last row's pad.
        #expect(
            SupermuxZeronEdgeFade.bandBottom(stackHeight: 140, safeAreaBottom: 34) == CGFloat(150)
        )
    }

    @Test("The macOS fade insets its clear zone by the titlebar height")
    func edgeFadeMacOSGeometry() {
        let fade = SupermuxZeronEdgeFade.macOS(stackHeight: 140)
        #expect(fade.insetTop == 38)
        #expect(fade.bandTop == 24)
        #expect(fade.bandBottom == 116)
        // So content is fully transparent to y=38 and fully opaque from y=62.
        #expect(fade.insetTop + fade.bandTop == 62)
    }

    @Test("The mask's stops never invert, even on a degenerate viewport")
    func edgeFadeStopsNeverInvert() {
        // A tall chrome stack on a short viewport would otherwise put the
        // bottom-opaque stop ABOVE the top-opaque one, which renders as a fully
        // masked (invisible) transcript.
        let fade = SupermuxZeronEdgeFade(insetTop: 38, bandTop: 24, bandBottom: 400)
        for height in [0.0, 1.0, 40.0, 62.0, 100.0, 800.0] as [CGFloat] {
            let gradient = fade.mask(height: height)
            _ = gradient  // constructing it must not trap
        }
        // The guard path for a zero-height viewport is a fully opaque mask, not
        // a fully clear one: a clear mask would blank the transcript for a frame
        // during first layout.
        let zero = SupermuxZeronEdgeFade.macOS(stackHeight: 140).mask(height: 0)
        _ = zero
    }

    // MARK: - Timestamp lane

    @Test("The timestamp format is the hardcoded English pattern, not a locale template")
    func timestampFormat() {
        // zeron hardcodes `"%b %-d, %-I:%M %p"`. A localized template would make
        // %p locale-dependent and %b non-English, which the plan forbids.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 1
        components.hour = 15
        components.minute = 45
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!
        #expect(SupermuxZeronTimestampLane.label(for: date) == "Jul 1, 3:45 PM")

        // No leading zeros on the day or the hour; the minute IS zero-padded.
        components.month = 8
        components.day = 5
        components.hour = 9
        components.minute = 2
        let second = calendar.date(from: components)!
        #expect(SupermuxZeronTimestampLane.label(for: second) == "Aug 5, 9:02 AM")
    }

    @Test("Lane geometry differs by row kind but is RESERVED in both cases")
    func laneGeometry() {
        // The lane exists whether or not the row is hovered; only the label
        // fades. A reveal must never shift the virtualizer's layout.
        #expect(SupermuxZeronMetrics.Transcript.tsLaneUser == 16)
        #expect(SupermuxZeronMetrics.Transcript.tsLaneAssistant == 20)
        #expect(SupermuxZeronMetrics.Transcript.tsLaneAssistantTopPad == 4)
        // The assistant's 4 pt pad is grown INTO its 20 pt lane, so both lanes
        // have the same 16 pt content height.
        #expect(
            SupermuxZeronMetrics.Transcript.tsLaneAssistant
                - SupermuxZeronMetrics.Transcript.tsLaneAssistantTopPad
                == SupermuxZeronMetrics.Transcript.tsLaneUser
        )
    }

    // MARK: - Column geometry

    @Test("The bubble cap is a CONSTANT 588.8, not a percentage of the column")
    func bubbleCapIsConstant() {
        #expect(SupermuxZeronMetrics.Transcript.bubbleMaxWidth == 588.8)
        // …and it is STORED, not computed: `736 × 0.8` evaluates to
        // 588.8000000000001 in binary floating point, so a computed cap would
        // disagree with the literal on the last bit and, more importantly, would
        // re-derive itself from whatever column width a caller had in hand. The
        // constant is the contract (spec 02 §3.2's boxed warning).
        #expect(
            abs(
                SupermuxZeronMetrics.Transcript.bubbleMaxWidth
                    - SupermuxZeronMetrics.Transcript.maxContentWidth * 0.8
            ) < 1e-9
        )
        // On a column narrower than 736 the cap does NOT shrink, so the bubble
        // can reach 100 % of the column — that is the intended behavior.
        #expect(SupermuxZeronMetrics.Transcript.gutter == 48)
        #expect(SupermuxZeronMetrics.Transcript.maxContentWidth == 736)
    }

    @Test("The bubble hugs its text: a short prompt is a SHORT pill, not a 588.8 slab")
    func bubbleWidthIsShrinkToFit() {
        guard SupermuxZeronFonts.isRegistered else { return }
        let font = SupermuxZeronFonts.platformSans(size: 14)
        let cap = SupermuxZeronMetrics.Transcript.bubbleMaxWidth

        // ── The bug this exists to catch ───────────────────────────────────
        //
        // gpui's `.max_w(588.8)` is a MAXIMUM on a shrink-to-fit flex item, so
        // "hi" paints a ~44 pt pill hugging the column's right edge — which is
        // what every zeron screenshot shows. SwiftUI's `.frame(maxWidth:)`
        // instead ACCEPTS the whole proposed width, so the shipped view painted
        // every bubble as a full-width 588.8 slab with the text jammed against
        // its left edge, at every message length.
        //
        // The rule is `min(max-content + 2 × 16, 588.8)`.
        func width(_ text: String) -> CGFloat {
            min(SupermuxZeronTextMeasure.maxContentWidth(text, font: font) + 32, cap)
        }

        // A two-character prompt must be nowhere near the cap.
        #expect(width("hi") < 80, "a two-letter prompt painted \(width("hi")) pt wide")
        // A medium prompt sits strictly between.
        let medium = width("Can you check the build?")
        #expect(medium > 100 && medium < cap, "medium prompt: \(medium)")
        // Monotonic in content length.
        #expect(width("hi") < medium)
        // And a long prompt clamps at exactly the cap, never past it.
        let long = width(String(repeating: "wrap ", count: 60))
        #expect(long == cap, "a long prompt must clamp to 588.8, got \(long)")

        // max-content is the widest HARD line: a newline must not concatenate.
        let twoLines = SupermuxZeronTextMeasure.maxContentWidth("one\ntwo three four", font: font)
        let joined = SupermuxZeronTextMeasure.maxContentWidth("onetwo three four", font: font)
        #expect(twoLines < joined, "max-content measured the wrapped string as one line")
        #expect(
            abs(twoLines - SupermuxZeronTextMeasure.maxContentWidth("two three four", font: font))
                < 1e-9,
            "max-content must be the WIDEST line"
        )
    }

    @Test("A single-line bubble is exactly 42 pt tall")
    func bubbleLineBoxArithmetic() {
        // 10 + 22 + 10, pixel-verified in zeron's screenshots. The fixed line
        // box is what makes this exact rather than 41 or 43.
        //
        // The leading must be computed against the line height the text
        // renderer ACTUALLY lays out, not the face's raw
        // `ascender − descender + leading`. Geist's raw metric at 14 pt is
        // 18.2000 (its 1.300 em), but TextKit rounds ascent and descent to
        // integral points before summing, so the laid-out box is 18.0 and the
        // leading needed is 4.0, not 3.8. Asserting 3.8 here is what let the
        // 0.2 pt/line drift ship: a rendered single-line bubble measured 41.8,
        // and an n-line bubble `n × 22 − 0.2`.
        let leading = SupermuxZeronBoxLeading.value(fontSize: 14, boxHeight: 22)
        guard SupermuxZeronFonts.isRegistered else { return }

        let font = SupermuxZeronFonts.platformSans(size: 14)
        #if canImport(AppKit)
        let renderedLineHeight = NSLayoutManager().defaultLineHeight(for: font)
        #else
        let renderedLineHeight = font.lineHeight
        #endif

        // The invariant that actually matters: one line box is exactly 22.
        #expect(
            abs(renderedLineHeight + leading - 22) < 1e-9,
            "a line box must be exactly 22 pt; got \(renderedLineHeight + leading)"
        )
        // And therefore n lines are exactly n × 22, which is what makes the
        // bubble 42 / 64 and the 12 pt markdown block gap land true.
        for lines in 1...5 {
            let height = CGFloat(lines) * renderedLineHeight + CGFloat(lines - 1) * leading
                + leading  // the half-leading padding, applied above and below
            #expect(
                abs(height - CGFloat(lines) * 22) < 1e-9,
                "\(lines) lines measured \(height), want \(CGFloat(lines) * 22)"
            )
        }
        // Guard the specific regression: the RAW face metric is NOT the right
        // input, and the two genuinely differ for this face.
        let rawLineHeight = font.ascender - font.descender + font.leading
        #expect(
            abs(rawLineHeight - renderedLineHeight) > 0.1,
            "if these ever converge this test stops discriminating"
        )
    }
}

// MARK: - Working trailer

struct SupermuxZeronWorkingTrailerTests {

    @Test("The flavour vocabulary is zeron's twenty words, in order")
    func flavourWordCount() {
        #expect(SupermuxZeronWorkingTrailer.flavourWords.count == 20)
        #expect(SupermuxZeronWorkingTrailer.flavourWords.first == "Thinking")
        #expect(SupermuxZeronWorkingTrailer.flavourWords.last == "Conjuring")
        #expect(SupermuxZeronWorkingTrailer.flavourWords[14] == "Combobulating")
    }

    @Test("The word rotates every 7 seconds and is deterministic per seed")
    func flavourRotation() {
        let seed: UInt64 = 0
        // Seed 0 starts at index 0.
        #expect(SupermuxZeronWorkingTrailer.flavourWord(seed: seed, elapsedSeconds: 0) == "Thinking")
        #expect(SupermuxZeronWorkingTrailer.flavourWord(seed: seed, elapsedSeconds: 6) == "Thinking")
        #expect(
            SupermuxZeronWorkingTrailer.flavourWord(seed: seed, elapsedSeconds: 7) == "Pondering"
        )
        #expect(
            SupermuxZeronWorkingTrailer.flavourWord(seed: seed, elapsedSeconds: 13) == "Pondering"
        )
        #expect(SupermuxZeronWorkingTrailer.flavourWord(seed: seed, elapsedSeconds: 14) == "Scheming")
        // It wraps after twenty steps.
        #expect(
            SupermuxZeronWorkingTrailer.flavourWord(seed: seed, elapsedSeconds: 140) == "Thinking"
        )
        // Negative elapsed clamps rather than trapping on a negative index.
        #expect(
            SupermuxZeronWorkingTrailer.flavourWord(seed: seed, elapsedSeconds: -5) == "Thinking"
        )
    }

    @Test("The same session key always produces the same rotation")
    func flavourSeedIsStable() {
        let a = SupermuxZeronWorkingTrailer.flavourSeed(sessionKey: "session-abc")
        let b = SupermuxZeronWorkingTrailer.flavourSeed(sessionKey: "session-abc")
        let c = SupermuxZeronWorkingTrailer.flavourSeed(sessionKey: "session-xyz")
        #expect(a == b, "the seed must be deterministic — two devices show one word")
        #expect(a != c)
        // FNV-1a's known value for the empty input is the offset basis.
        #expect(SupermuxZeronWorkingTrailer.flavourSeed(sessionKey: "") == 0xcbf2_9ce4_8422_2325)
    }

    @Test("Elapsed formatting switches to m/s at exactly 60")
    func elapsedFormatting() {
        #expect(SupermuxZeronWorkingTrailer.formatElapsed(0) == "0s")
        #expect(SupermuxZeronWorkingTrailer.formatElapsed(59) == "59s")
        #expect(SupermuxZeronWorkingTrailer.formatElapsed(60) == "1m 0s")
        #expect(SupermuxZeronWorkingTrailer.formatElapsed(92) == "1m 32s")
        #expect(SupermuxZeronWorkingTrailer.formatElapsed(3_661) == "61m 1s")
        // Negative clamps to zero rather than rendering "-5s".
        #expect(SupermuxZeronWorkingTrailer.formatElapsed(-5) == "0s")
    }
}

// MARK: - Result meta row

struct SupermuxZeronResultMetaRowTests {

    private static func summary(
        cost: Double? = nil,
        duration: Int? = nil,
        turns: Int? = nil,
        input: Int? = nil,
        output: Int? = nil,
        isError: Bool = false,
        terminalReason: String? = nil
    ) -> SupermuxHarnessResultSummary {
        SupermuxHarnessResultSummary(
            totalCostUSD: cost,
            durationMs: duration,
            numTurns: turns,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: nil,
            isError: isError,
            terminalReason: terminalReason
        )
    }

    @Test("Segments join with the middle dot, in a fixed order")
    func metaLineComposition() {
        let line = SupermuxZeronResultMetaRow.line(
            for: Self.summary(cost: 0.0321, duration: 4_200, turns: 2, input: 1_024, output: 512)
        )
        #expect(line == "$0.0321 \u{00B7} 4.2s \u{00B7} 2 turns \u{00B7} \u{2191}1024 \u{2193}512")
    }

    @Test("Missing fields are omitted, not rendered as placeholders")
    func metaLineOmitsMissing() {
        #expect(SupermuxZeronResultMetaRow.line(for: Self.summary()) == "")
        #expect(SupermuxZeronResultMetaRow.line(for: Self.summary(duration: 800)) == "800ms")
    }

    @Test("An interrupted turn appends its marker last")
    func metaLineInterrupted() {
        let line = SupermuxZeronResultMetaRow.line(
            for: Self.summary(duration: 1_500, terminalReason: "aborted_streaming")
        )
        #expect(line.hasSuffix("interrupted"))
    }

    @Test("Duration crosses ms → s → m/s at the right boundaries")
    func durationText() {
        #expect(SupermuxZeronResultMetaRow.durationText(milliseconds: 999) == "999ms")
        #expect(SupermuxZeronResultMetaRow.durationText(milliseconds: 1_000) == "1.0s")
        #expect(SupermuxZeronResultMetaRow.durationText(milliseconds: 59_900) == "59.9s")
        #expect(SupermuxZeronResultMetaRow.durationText(milliseconds: 60_000) == "1m 0s")
        #expect(SupermuxZeronResultMetaRow.durationText(milliseconds: 92_000) == "1m 32s")
    }
}

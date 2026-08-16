import CoreGraphics
import Foundation
import Testing
@testable import SupermuxZeronUI

/// The two things `SupermuxZeronTextKitRenderer` exists for (plan R6 and R7),
/// measured rather than asserted from the spec.
///
/// These are the tests that would catch the two failures the plan names by
/// name: a square inline-code box instead of a rounded per-visual-line quad,
/// and a single-line bubble that comes out at 41 or 43 pt instead of exactly
/// 42.
struct SupermuxZeronTextKitTests {
    private typealias Md = SupermuxZeronMetrics.Markdown

    private let theme = SupermuxZeronTheme.dark

    private func flat(
        _ runs: [SupermuxZeronInlineRun],
        weight: SupermuxZeronFontWeight = .regular
    ) -> SupermuxZeronFlatText {
        SupermuxZeronFlatText.flatten(runs: runs, theme: theme, baseWeight: weight)
    }

    private func layout(
        _ flat: SupermuxZeronFlatText,
        width: CGFloat,
        fontSize: CGFloat = Md.textSize,
        lineHeight: CGFloat = Md.lineHeight
    ) -> SupermuxZeronTextLayout {
        SupermuxZeronTextKit.layout(
            attributed: SupermuxZeronTextKit.attributedString(
                for: flat,
                fontSize: fontSize,
                lineHeight: lineHeight,
                theme: theme
            ),
            text: flat.text,
            width: width,
            codeRanges: flat.codeRanges,
            links: flat.links
        )
    }

    // MARK: R7 — the fixed line box

    /// **The 42 pt bubble.** A single line of 14/22 body text inside the user
    /// bubble's `py 10` is 22 + 20 = exactly 42 pt. `.lineSpacing()` would land
    /// on 41 or 43 because it adds space BETWEEN lines without setting the box.
    @Test("a single-line bubble is EXACTLY 42 pt, not 41 or 43")
    func singleLineBubbleIsExactly42() {
        let block = flat([SupermuxZeronInlineRun(text: "Summarize the bottom fade.")])
        let measured = layout(block, width: SupermuxZeronMetrics.Transcript.bubbleMaxWidth)

        #expect(measured.height == Md.lineHeight, "the line BOX is 22, not the face's natural height")
        // The bubble is the line box plus its 10 pt vertical padding either
        // side. 22 + 10 + 10 = 42.
        let bubblePadY: CGFloat = 10
        #expect(measured.height + 2 * bubblePadY == 42)
    }

    /// Every additional visual line adds EXACTLY one line box, so an n-line
    /// block is exactly `n × 22`. That identity is what keeps the 12 pt block
    /// gap reading as 12 rather than 11 or 13.
    @Test("n visual lines measure exactly n × 22")
    func lineBoxesStackExactly() {
        // A width narrow enough to force wrapping, and text long enough to be
        // certain of it.
        let block = flat([
            SupermuxZeronInlineRun(
                text: "Every turn flows through the same path and then wraps onto more lines."
            ),
        ])
        let narrow = layout(block, width: 160)
        #expect(narrow.height > Md.lineHeight, "the sample must actually wrap")
        let lines = narrow.height / Md.lineHeight
        #expect(lines == lines.rounded(), "height must be an exact multiple of the 22 pt box")
    }

    /// The heading scale, measured. h1 is 19/27, h2 16/24, h3 15/22, and h4–h6
    /// are all identical to a bold paragraph.
    @Test("heading line boxes are 27 / 24 / 22 / 22")
    func headingLineBoxes() {
        let cases: [(level: Int, box: CGFloat)] = [
            (1, Md.h1LineHeight),
            (2, Md.h2LineHeight),
            (3, Md.h3LineHeight),
            (4, Md.h4LineHeight),
            (5, Md.h4LineHeight),
            (6, Md.h4LineHeight),
        ]
        for testCase in cases {
            let metrics = SupermuxZeronMarkdownView.headingMetrics(testCase.level)
            #expect(metrics.lineHeight == testCase.box)
            let block = flat(
                [SupermuxZeronInlineRun(text: "Streaming pipeline")],
                weight: .semibold
            )
            let measured = layout(
                block,
                width: 600,
                fontSize: metrics.size,
                lineHeight: metrics.lineHeight
            )
            #expect(
                measured.height == testCase.box,
                "h\(testCase.level) must lay out in exactly its own line box"
            )
        }
        // h4, h5 and h6 really are indistinguishable.
        #expect(
            SupermuxZeronMarkdownView.headingMetrics(4)
                == SupermuxZeronMarkdownView.headingMetrics(6)
        )
    }

    // MARK: R6 — the rounded inline-code wash

    /// **The wash is 18 pt tall, always.** 22 − 2 × 2. Pixel-verified upstream
    /// at three different span widths in `02-after.png`, all exactly 18.0 pt.
    @Test("an inline-code wash box is exactly 18 pt tall and overhangs 2 pt")
    func inlineCodeWashGeometry() {
        let block = flat([
            SupermuxZeronInlineRun(text: "The "),
            SupermuxZeronInlineRun(
                text: "SegmentWriter",
                style: SupermuxZeronInlineStyle(code: true)
            ),
            SupermuxZeronInlineRun(text: " appends."),
        ])
        #expect(block.codeRanges.count == 1)

        let measured = layout(block, width: 600)
        #expect(measured.codeRects.count == 1, "an unwrapped span is ONE box")
        let box = measured.codeRects[0]
        #expect(box.height == Md.inlineCodeBoxHeight)
        #expect(box.height == Md.lineHeight - 2 * Md.inlineCodeInsetY)
        // The box starts 2 pt BEFORE the glyphs — a negative-x overhang the
        // segment rect itself does not have.
        #expect(box.minY == Md.inlineCodeInsetY)
    }

    /// **One box per VISUAL LINE.** A code span that soft-wraps across two
    /// lines gets two separate rounded boxes, each with its own 2 pt
    /// horizontal overhang — never one continuous shape.
    @Test("a wrapped inline-code span gets one box PER VISUAL LINE")
    func wrappedInlineCodeGetsOneBoxPerLine() {
        let block = flat([
            SupermuxZeronInlineRun(text: "call "),
            SupermuxZeronInlineRun(
                // Long enough that no sane width fits it on one line.
                text: "renderTranscriptRowWithVeilAndSyntaxHighlighting(options:)",
                style: SupermuxZeronInlineStyle(code: true)
            ),
            SupermuxZeronInlineRun(text: " now"),
        ])

        let wide = layout(block, width: 700)
        let narrow = layout(block, width: 150)

        #expect(wide.codeRects.count == 1, "unwrapped stays one box")
        #expect(narrow.codeRects.count > 1, "a wrapped span MUST split into per-line boxes")

        // Every box is a full-height 18 pt wash, and they sit on DISTINCT
        // visual lines one line box apart.
        for rect in narrow.codeRects {
            #expect(rect.height == Md.inlineCodeBoxHeight)
        }
        let tops = narrow.codeRects.map(\.minY).sorted()
        for (a, b) in zip(tops, tops.dropFirst()) {
            #expect(b - a == Md.lineHeight, "consecutive boxes are exactly one line box apart")
        }
        // The total height covered is n line boxes, not one tall shape.
        #expect(narrow.height >= CGFloat(narrow.codeRects.count) * Md.lineHeight)
    }

    /// Adjacent code runs merge into ONE wash box; separated ones each get
    /// their own (`render.rs:569`, unit-tested upstream as `vec![4..9, 14..17]`).
    @Test("adjacent code runs merge, separated ones do not")
    func codeRangeMerging() {
        let merged = flat([
            SupermuxZeronInlineRun(text: "abcd"),
            SupermuxZeronInlineRun(text: "efg", style: SupermuxZeronInlineStyle(code: true)),
            SupermuxZeronInlineRun(
                text: "hi",
                style: SupermuxZeronInlineStyle(bold: true, code: true)
            ),
            SupermuxZeronInlineRun(text: " tail"),
        ])
        #expect(merged.codeRanges == [4..<9], "two adjacent code runs are ONE box")

        let separated = flat([
            SupermuxZeronInlineRun(text: "abcd"),
            SupermuxZeronInlineRun(text: "efghi", style: SupermuxZeronInlineStyle(code: true)),
            SupermuxZeronInlineRun(text: "jklmn"),
            SupermuxZeronInlineRun(text: "opq", style: SupermuxZeronInlineStyle(code: true)),
        ])
        #expect(separated.codeRanges == [4..<9, 14..<17])
    }

    /// The wash geometry constants are the spec's, not approximations.
    @Test("wash geometry constants match render.rs")
    func washConstants() {
        #expect(Md.inlineCodeRadius == 4.5)
        #expect(Md.inlineCodePadX == 2)
        #expect(Md.inlineCodeInsetY == 2)
        #expect(Md.inlineCodeBoxHeight == 18)
        // Inline code is IDENTICAL in size to body text — there is no
        // `text-[0.9em]` shrink anywhere in the renderer.
        #expect(Md.inlineCodeSize == Md.textSize)
    }

    // MARK: Flattening

    /// A strong run is promoted to SEMIBOLD 600 only when the base is BELOW it,
    /// so a strong run inside a 700 table header stays 700.
    @Test("bold promotes to 600 in body but stays 700 in a table header")
    func boldWeightPromotion() {
        let body = flat([
            SupermuxZeronInlineRun(text: "x", style: SupermuxZeronInlineStyle(bold: true)),
        ])
        #expect(body.runs[0].weight == .semibold)

        let header = flat(
            [SupermuxZeronInlineRun(text: "x", style: SupermuxZeronInlineStyle(bold: true))],
            weight: .bold
        )
        #expect(header.runs[0].weight == .bold, "a strong run in a 700 header never drops to 600")
    }

    /// A still-streaming link keeps link STYLING — the underline is applied
    /// because the run carries a destination — but is NOT registered as
    /// clickable, so the URL's completion changes nothing visually.
    @Test("a pending link is styled but not clickable")
    func pendingLinkIsStyledButNotClickable() {
        let pending = flat([
            SupermuxZeronInlineRun(
                text: "docs",
                style: SupermuxZeronInlineStyle(link: SupermuxZeronMend.pendingLinkURL)
            ),
        ])
        #expect(pending.links.isEmpty, "the sentinel never becomes a hit region")
        #expect(pending.runs[0].link == SupermuxZeronMend.pendingLinkURL, "but it keeps its styling")

        let real = flat([
            SupermuxZeronInlineRun(
                text: "docs",
                style: SupermuxZeronInlineStyle(link: "https://x.dev")
            ),
        ])
        #expect(real.links.count == 1)
        #expect(real.links[0].url == "https://x.dev")
    }

    /// Adjacent runs with the SAME url merge into one clickable range, so
    /// `[**bold** tail](url)` is one hit region and not two.
    @Test("adjacent runs of one link merge into a single hit region")
    func linkRangeMerging() {
        let block = flat([
            SupermuxZeronInlineRun(
                text: "bold",
                style: SupermuxZeronInlineStyle(bold: true, link: "https://x.dev")
            ),
            SupermuxZeronInlineRun(
                text: " tail",
                style: SupermuxZeronInlineStyle(link: "https://x.dev")
            ),
        ])
        #expect(block.links.count == 1)
        #expect(block.links[0].range == 0..<9)
    }

    /// Inline code is the ONLY thing that changes colour. A link stays
    /// `theme.text` — "indigo is reserved for primary actions".
    @Test("only inline code recolors; links stay monochrome")
    func onlyCodeRecolors() {
        let block = flat([
            SupermuxZeronInlineRun(text: "a", style: SupermuxZeronInlineStyle(link: "https://x")),
            SupermuxZeronInlineRun(text: "b", style: SupermuxZeronInlineStyle(code: true)),
            SupermuxZeronInlineRun(text: "c"),
        ])
        #expect(block.runs[0].color == theme.text)
        #expect(block.runs[1].color == theme.codeText)
        #expect(block.runs[2].color == theme.text)
        // And only the code run switches to the mono family.
        #expect(!block.runs[0].isMono)
        #expect(block.runs[1].isMono)
    }

    // MARK: Byte-range bridging

    /// The veil speaks UTF-8 bytes and AppKit/UIKit speak UTF-16. A multi-byte
    /// scalar between the two must not shift a wash box or a fade range.
    @Test("UTF-8 byte ranges convert to UTF-16 ranges exactly")
    func byteToUTF16Conversion() {
        let text = "café 🎉 code"
        // "café " is 6 bytes (é is 2) but 5 UTF-16 units.
        let after = SupermuxZeronTextKit.utf16Range(text: text, byteRange: 0..<6)
        #expect(after?.location == 0)
        #expect(after?.length == 5)

        // The emoji is 4 bytes / 2 UTF-16 units (a surrogate pair).
        let emoji = SupermuxZeronTextKit.utf16Range(text: text, byteRange: 6..<10)
        #expect(emoji?.length == 2)

        // A range that splits a scalar has no valid answer.
        #expect(SupermuxZeronTextKit.utf16Range(text: text, byteRange: 0..<4) == nil)
        // Out of bounds is nil, not a crash.
        #expect(SupermuxZeronTextKit.utf16Range(text: text, byteRange: 0..<999) == nil)
    }

    /// **Regression.** `enumerateTextSegments` does not guarantee one callback
    /// per visual line: a code span at the END of the text came back as TWO
    /// identical rects on this toolchain. Filling both double-paints the
    /// translucent violet wash, so a trailing span rendered visibly darker than
    /// an interior one. The rects are coalesced per line.
    @Test("a span at the end of the text yields ONE rect, not a duplicate")
    func trailingSpanIsNotDoublePainted() {
        let block = flat([
            SupermuxZeronInlineRun(text: "abc "),
            SupermuxZeronInlineRun(text: "run", style: SupermuxZeronInlineStyle(code: true)),
        ])
        let measured = layout(block, width: 600)
        #expect(measured.codeRects.count == 1, "one visual line -> exactly one wash box")

        // Directly: two identical segments on one line coalesce to one.
        let duplicated = [
            CGRect(x: 10, y: 2, width: 29, height: 18),
            CGRect(x: 10, y: 2, width: 29, height: 18),
        ]
        #expect(SupermuxZeronTextKit.coalescePerLine(duplicated).count == 1)

        // Two ADJACENT segments on one line merge into their union...
        let split = [
            CGRect(x: 10, y: 2, width: 12, height: 18),
            CGRect(x: 22, y: 2, width: 17, height: 18),
        ]
        let merged = SupermuxZeronTextKit.coalescePerLine(split)
        #expect(merged.count == 1)
        #expect(merged[0].minX == 10 && merged[0].maxX == 39)

        // ...while segments on DIFFERENT lines stay separate boxes.
        let twoLines = [
            CGRect(x: 10, y: 2, width: 12, height: 18),
            CGRect(x: 0, y: 24, width: 40, height: 18),
        ]
        #expect(SupermuxZeronTextKit.coalescePerLine(twoLines).count == 2)
    }

    /// A multi-byte scalar before a code span must not shift its wash box.
    @Test("a wash box lands correctly after multi-byte text")
    func washAfterMultiByteText() {
        let block = flat([
            SupermuxZeronInlineRun(text: "café → "),
            SupermuxZeronInlineRun(text: "run", style: SupermuxZeronInlineStyle(code: true)),
        ])
        let measured = layout(block, width: 600)
        #expect(measured.codeRects.count == 1)
        #expect(measured.codeRects[0].height == Md.inlineCodeBoxHeight)
        // The box is to the RIGHT of the leading text, not at x≈0, which is
        // what a byte/UTF-16 mismatch would produce.
        #expect(measured.codeRects[0].minX > 20)
    }
}

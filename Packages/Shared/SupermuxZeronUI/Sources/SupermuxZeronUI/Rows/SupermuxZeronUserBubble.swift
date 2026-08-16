//
//  SupermuxZeronUserBubble.swift
//  SupermuxZeronUI
//
//  The user message bubble. Spec 02 §3.
//
//  | Property        | Value                                                |
//  |-----------------|------------------------------------------------------|
//  | alignment       | trailing (`justify_end`)                              |
//  | max width       | 588.8 = `736 × 0.8`, a CONSTANT (see below)            |
//  | background      | `userBubbleBG()` — `wash(0.08)` dark / `wash(0.04)` light |
//  | corner radius   | 16, uniform, `.continuous` (§0.3 C15)                 |
//  | padding         | 16 horizontal / 10 vertical                            |
//  | text            | 14 pt Geist regular in a FIXED 22 pt line box, `theme.text` |
//  | border / shadow | none / none                                            |
//  | pending echo    | the whole bubble at opacity 0.65                       |
//
//  Single-line height is therefore exactly `10 + 22 + 10 = 42`, two-line `64` —
//  both pixel-verified in zeron's screenshots.
//
//  ── The max width is a CONSTANT, not a percentage ──
//
//  `MAX_CONTENT_WIDTH × 0.8`, evaluated once. On a window narrow enough that the
//  column is under 736 pt the cap stays 588.8, so the bubble can reach 100 % of
//  the column. Reproduce the constant, never a percentage of the parent.
//
//  ── `min_w_0` and its SwiftUI analogue ──
//
//  gpui text answers min/max-content probes with its UNWRAPPED width, so without
//  `min_w_0` the bubble's automatic min-size is the full single-line width: the
//  flex item cannot shrink, `justify_end` pushes the overflow off the LEFT edge,
//  and a long prompt renders as one clipped line. The SwiftUI hazard is the same
//  shape — a `Text` that refuses to compress — and the fix is
//  `.fixedSize(horizontal: false, vertical: true)` inside a bounded
//  `.frame(maxWidth: 588.8, alignment: .trailing)`.
//
//  ── The 22 pt line box ──
//
//  gpui `.line_height(px(22))` sets a FIXED line box; the glyph run is centred
//  in it regardless of the face's own ascent/descent. SwiftUI's `.lineSpacing`
//  only adds space BETWEEN lines, so it leaves the first line's ascent wrong and
//  every derived height off by a fraction (plan R7). The fix here is
//  `lineSpacing(box - faceLineHeight)` PLUS half that leading as vertical
//  padding, which recentres the first and last lines and makes the composite
//  height exactly `n × 22`. Measured from the real `NSFont`/`UIFont`, never
//  guessed.
//

public import SwiftUI

/// The trailing user prompt bubble.
///
/// Immutable values only; safe below a `LazyVStack` boundary.
public struct SupermuxZeronUserBubble: View {
    private let text: String
    /// The optimistic local echo, before the CLI replays the prompt.
    private let isPending: Bool
    private let theme: SupermuxZeronTheme

    public init(text: String, isPending: Bool = false, theme: SupermuxZeronTheme) {
        self.text = text
        self.isPending = isPending
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: 0) {
            // `justify_end`: the bubble hugs the column's trailing edge.
            Spacer(minLength: 0)
            Text(text)
                .font(SupermuxZeronFonts.sans(size: 14))
                .foregroundStyle(theme.text)
                .supermuxZeronFixedLineBox(fontSize: 14, boxHeight: 22)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // The cap is `min(max-content, 588.8)`, NOT a flat 588.8.
                // gpui's `max_w` is a MAXIMUM on a shrink-to-fit flex item, so a
                // two-word prompt paints a two-word pill. SwiftUI's
                // `.frame(maxWidth:)` instead ACCEPTS the full proposed width
                // whenever the parent offers it, which painted every bubble as a
                // full-width 588.8 slab with the text jammed left — the single
                // most visible difference from the screenshots, where a short
                // prompt is a short pill hugging the right edge.
                //
                // `.fixedSize(horizontal: true)` is not the fix either: it
                // refuses to wrap at all and a long prompt runs off the column.
                // Measuring max-content and capping it reproduces flexbox
                // exactly — verified against the shipped layout at column widths
                // 736 and 400.
                .frame(maxWidth: bubbleWidthCap, alignment: .leading)
                .background(
                    RoundedRectangle(
                        cornerRadius: SupermuxZeronMetrics.Theme.bubbleRadius,
                        style: .continuous
                    )
                    .fill(theme.userBubbleBG())
                )
                .opacity(isPending ? 0.65 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// `min(maxContentWidth + 2 × 16, 588.8)` — the flex `max_w` semantic.
    ///
    /// A pure function of the text and the face; no state is written.
    private var bubbleWidthCap: CGFloat {
        let content = SupermuxZeronTextMeasure.maxContentWidth(
            text,
            font: SupermuxZeronFonts.platformSans(size: 14)
        )
        return min(content + 32, SupermuxZeronMetrics.Transcript.bubbleMaxWidth)
    }
}

// MARK: - Max-content measurement

/// `max-content` width: the widest HARD line, unwrapped.
///
/// This is CSS/flexbox's `max-content`, which is what gpui's shrink-to-fit flex
/// item resolves to before `max_w` clamps it. SwiftUI has no way to ask a `Text`
/// for it, so it is measured with CoreText against the same face the view
/// renders with — which also means a fallback face (plan R10) still produces a
/// self-consistent bubble, just at that face's widths.
///
/// A pure measurement helper over a font and a string; the receiver would be
/// `String`, and extending `String` with a font-measuring method is worse.
///
/// lint:allow namespace-enum, namespace-type — pure CoreText measurement (spec 02 §3.2).
enum SupermuxZeronTextMeasure {
    static func maxContentWidth(_ text: String, font: SupermuxZeronPlatformFont) -> CGFloat {
        var widest: CGFloat = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let attributed = NSAttributedString(
                string: String(line),
                attributes: [.font: font]
            )
            let typographic = CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(attributed),
                nil,
                nil,
                nil
            )
            widest = max(widest, ceil(typographic))
        }
        return widest
    }
}

// MARK: - Fixed line box

/// A fixed line box, the SwiftUI analogue of gpui's `.line_height(px(N))`.
///
/// `lineSpacing` supplies the extra leading between lines; the matching half-
/// leading as vertical padding recentres the first and last lines, so `n` lines
/// measure exactly `n × boxHeight`. Both values are derived from the REAL face
/// metrics, so a fallback font (R10) still produces a correct box even though
/// its wrapping differs.
///
/// Kept `internal` on purpose: the markdown pipeline owns the TextKit path that
/// supersedes this for rich text (plan R6/R7). This is the plain-`Text` case —
/// the bubble, the notice line, the working trailer.
extension View {
    func supermuxZeronFixedLineBox(fontSize: CGFloat, boxHeight: CGFloat) -> some View {
        let leading = SupermuxZeronBoxLeading.value(fontSize: fontSize, boxHeight: boxHeight)
        return lineSpacing(leading).padding(.vertical, leading / 2)
    }
}

/// The extra leading a fixed line box needs, measured from the REAL face.
///
/// Geist at 14 pt measures `ascender 14.070 − descender 4.130 + leading 0` =
/// **18.200**, matching the vendored face's `1.300 em` (W0's
/// `SupermuxZeronFonts.Metrics`). So a 22 pt box wants 3.8 pt of leading, split
/// 1.9 above and below. Measured rather than derived from the constant so that a
/// fallback face (R10) still yields a correct box height even though its
/// wrapping differs.
///
/// A pure measured-metrics helper with no natural receiver to extend: the
/// receiver would be `View`, and this is font math, not view behavior.
///
/// lint:allow namespace-enum, namespace-type — measured face metrics (plan R7).
enum SupermuxZeronBoxLeading {
    static func value(fontSize: CGFloat, boxHeight: CGFloat) -> CGFloat {
        let font = SupermuxZeronFonts.platformSans(size: fontSize)
        return max(boxHeight - renderedLineHeight(of: font), 0)
    }

    /// The line height SwiftUI's text layout ACTUALLY uses for `font`.
    ///
    /// Not `ascender - descender + leading`: that is the face's raw metric
    /// (18.2000 for Geist at 14 pt), but TextKit rounds ascent and descent to
    /// integral points before summing, so the laid-out line box is 18.0. Using
    /// the raw value made `lineSpacing` 0.2 pt too small on every line, and an
    /// n-line bubble measured `n × 22 − 0.2` instead of `n × 22` — verified:
    /// 21.800 / 43.800 / 65.800 against the required 22 / 44 / 66. That drift
    /// is exactly the R7 failure the fixed line box exists to prevent, and it
    /// compounds against the 12 pt markdown block gap.
    ///
    /// `NSLayoutManager.defaultLineHeight` reports the rounded value directly on
    /// macOS; UIKit's `UIFont.lineHeight` is already the rounded one.
    private static func renderedLineHeight(of font: SupermuxZeronPlatformFont) -> CGFloat {
        #if canImport(AppKit)
        return NSLayoutManager().defaultLineHeight(for: font)
        #else
        return font.lineHeight
        #endif
    }
}

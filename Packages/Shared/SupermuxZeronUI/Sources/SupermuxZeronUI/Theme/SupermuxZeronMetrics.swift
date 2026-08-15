//
//  SupermuxZeronMetrics.swift
//  SupermuxZeronUI
//
//  Every layout and motion constant in the zeron chat pane. Plan §1.4 / §1.5.
//
//  ── Units ──
//
//  **Every value is a literal POINT** (§0.3 C14). zeron's gpui codebase never
//  calls `rems()` and never uses a Tailwind `.gap_N()` shorthand — a repo-wide
//  grep returns zero hits for both. The Tailwind names quoted in comments
//  (`h-6`, `px-4`) are citations of the ORIGINAL web source; the Rust already
//  converted them, and so has this file. Never re-derive a value from a
//  Tailwind step.
//
//  ── Analytic heights ──
//
//  zeron's entire fold model is analytic (`chipsHeight`, `outputDetailHeight`,
//  `diffDetailHeight`) so a tween can interpolate two KNOWN heights and a
//  virtualizer never measures an offscreen row. Drive `.frame(height:)` from
//  these functions rather than letting SwiftUI measure (plan R4). The mono
//  bodies are fixed-height rows with `.lineLimit(1)`, so content cannot exceed
//  the box.
//
//  lint:allow namespace-type — constant tables (data, not behavior).
//  (lint:allow)
//

public import CoreGraphics
public import Foundation
public import SwiftUI

/// The zeron layout + motion constant tables, grouped by owner.
/// lint:allow namespace-enum, namespace-type — the plan §1 constant table — data, not behavior; ships as exactly two files.
public enum SupermuxZeronMetrics {
    // MARK: - Theme (spec 01 §3.1)

    /// lint:allow namespace-enum, namespace-type — constant table (plan §1.4).
    public enum Theme {
        /// Unified window titlebar. The transcript's edge fade is inset by
        /// exactly this, so content is fully faded by the titlebar's bottom edge.
        public static let titlebarHeight: CGFloat = 38
        public static let titlebarTopPad: CGFloat = 2
        /// The reserved WorkingIndicator row above the composer. Reserved even
        /// when empty so the composer never shifts.
        public static let statusStripHeight: CGFloat = 24
        /// Height of the gradient fading the transcript into the panel edge.
        public static let transcriptFadeBand: CGFloat = 24
        /// User message bubble corner radius.
        public static let bubbleRadius: CGFloat = 16
        public static let panelRadius: CGFloat = 10
        /// Small controls: buttons, chips, hover plates.
        public static let controlRadius: CGFloat = 6
        /// In-card headers (Tailwind `h-11`).
        public static let headerHeight: CGFloat = 44

        public static let spaceXS: CGFloat = 4
        /// The workhorse spacing step — 41 call sites in zeron.
        public static let spaceSM: CGFloat = 8
        public static let spaceMD: CGFloat = 12
        public static let spaceLG: CGFloat = 16

        /// `SCRIM_ALPHA_DARK`; light derives as `0.32 × (a / 0.60)`.
        public static let scrimAlphaDark = 0.60
        /// Mirrors ``ZeronInk/fillScale``.
        public static let inkFillScale = ZeronInk.fillScale
        /// Mirrors ``ZeronInk/hairlineScale``.
        public static let inkHairlineScale = ZeronInk.hairlineScale
        /// Mirrors ``ZeronInk/hairlineAlphaCap``.
        public static let inkHairlineAlphaCap = ZeronInk.hairlineAlphaCap

        /// The frost tint alpha on a glass platform, both appearances
        /// ("glass-forward, like dark mode"). Opaque platforms use 1.0.
        public static let glassAlpha = 0.80
        /// Backdrop-blur sigma for floating menu/dialog glass.
        public static let menuBlur: CGFloat = 44
        /// Backdrop-blur sigma for the composer pill — deliberately lighter
        /// than menus. Preserve the RELATIVE difference even where the platform
        /// will not honor the exact sigma (plan R3).
        public static let composerPillBlur: CGFloat = 16
        /// Grid backdrop behind the empty-state canvas: 1 pt `hairline(0.035)`
        /// lines on a 44 pt step.
        public static let gridBackdropStep: CGFloat = 44
        public static let gridBackdropSpan: CGFloat = 2640
        public static let gridBackdropAlpha = 0.035
    }

    // MARK: - Transcript column (spec 02 §1–§2)

    /// lint:allow namespace-enum, namespace-type — constant table (plan §1.4).
    public enum Transcript {
        /// zeron's `46rem` at a 16 px base — a CONSTANT, not a computed rem.
        public static let maxContentWidth: CGFloat = 736
        /// Row horizontal gutters (zeron `px-4 @3xl:px-12`). iOS clamps this to
        /// `min(48, 16 + safeAreaInsets.leading)`; the max width does not change.
        public static let gutter: CGFloat = 48
        /// 736 × 0.8, stored as a CONSTANT so both platforms agree exactly.
        public static let bubbleMaxWidth: CGFloat = 588.8

        /// Gap above the first row of a new message entry (`turnStart`).
        public static let gapTurn: CGFloat = 14
        /// Gap between blocks inside one entry.
        public static let gapBlock: CGFloat = 8
        /// Gap between markdown blocks (§0.3 C6 — 12, from `render.rs`; a Rust
        /// test asserts it. Not the 14 in `mugen-pretext.md`).
        public static let mdBlockGap: CGFloat = 12

        /// Top gap above row 0 = titlebar 38 + gapTurn 14 + 10.
        public static let row0TopGap: CGFloat = 62

        /// The extra clearance the last row pads itself by, past the fade band,
        /// so settled text and the revealed timestamp never sit inside it.
        public static let lastRowExtraClearance: CGFloat = 8

        /// Reserved timestamp lane heights. The lane exists whether or not the
        /// row is hovered — only the LABEL fades. Geometry must not diverge
        /// between platforms.
        public static let tsLaneUser: CGFloat = 16
        public static let tsLaneAssistant: CGFloat = 20
        /// Top padding inside the 20 pt assistant lane (content lane = 16).
        public static let tsLaneAssistantTopPad: CGFloat = 4

        public static let attThumbWidth: CGFloat = 112
        public static let attThumbHeight: CGFloat = 80
        public static let attStripHeight: CGFloat = 90
        public static let attThumbGap: CGFloat = 8
        public static let attThumbRadius: CGFloat = 8
        /// The image inside the 8 pt thumb frame is clipped at 7.
        public static let attThumbImageRadius: CGFloat = 7

        public static let jumpPillHeight: CGFloat = 30
        /// `rounded_full` on a 30 pt pill.
        public static let jumpPillRadius: CGFloat = 15
        public static let jumpPillPadLeading: CGFloat = 11
        public static let jumpPillPadTrailing: CGFloat = 13
        public static let jumpPillGap: CGFloat = 6
        public static let jumpPillTextSize: CGFloat = 13

        /// The last row's bottom pad.
        ///
        /// `bottomClearance` is the measured composer+strip height the
        /// transcript scrolls under; `runway` is the own-turn reservation (0
        /// unless a locally-sent turn is anchored). iOS adds
        /// `safeAreaInsets.bottom` on top, and grows the fade's `bandBottom` by
        /// the same amount.
        public static func lastRowBottomPad(
            bottomClearance: CGFloat,
            runway: CGFloat = 0,
            safeAreaBottom: CGFloat = 0
        ) -> CGFloat {
            bottomClearance
                + Theme.transcriptFadeBand
                + lastRowExtraClearance
                + runway
                + safeAreaBottom
        }
    }

    // MARK: - Tool chips (spec 03 §9)

    /// lint:allow namespace-enum, namespace-type — constant table (plan §1.4).
    public enum Chips {
        /// The chip ROW — equally, one guide-rail segment.
        public static let rowHeight: CGFloat = 38
        /// The card INSIDE the row, **including its 1 pt border** (§0.3 C9 —
        /// 30, not the screenshots' 32; `strokeBorder` draws inside, which is
        /// what fixes the 2 px/chip drift). 38 − 30 = 8, split 4 pt of visible
        /// rail above and 4 pt below.
        public static let cardHeight: CGFloat = 30
        /// Zero, deliberately — rows stack flush so the rail reads continuous.
        public static let gap: CGFloat = 0
        public static let topPad: CGFloat = 2
        public static let cardRadius: CGFloat = 9

        /// Rail inset from the content column's left edge. The same 12 that
        /// centers it under the header's 18 pt chevron tile.
        public static let railInset: CGFloat = 12
        public static let railWidth: CGFloat = 1
        /// Card leading offset from the content column = 12 + 1 + 12.
        public static let cardLeadingInset: CGFloat = 25

        public static let groupHeaderHeight: CGFloat = 26
        public static let groupHeaderPadX: CGFloat = 4
        public static let groupHeaderGap: CGFloat = 8

        public static let tileSize: CGFloat = 18
        public static let tileRadius: CGFloat = 5
        public static let tileIconGlyph: CGFloat = 12
        public static let tileChevronGlyph: CGFloat = 10

        public static let textSize: CGFloat = 12
        public static let subjectAlpha = 0.85

        public static let outputLineHeight: CGFloat = 18
        /// py 6 × 2.
        public static let outputBodyPad: CGFloat = 12
        public static let outputPadX: CGFloat = 12
        public static let outputTextSize: CGFloat = 11.5
        public static let tailTextSize: CGFloat = 10.5
        public static let detailSeparator: CGFloat = 1
        public static let blobAffordanceHeight: CGFloat = 24
        public static let blobAffordancePadX: CGFloat = 12
        public static let blobAffordanceTextSize: CGFloat = 10.5

        public static let outputMaxLines = 24
        public static let diffMaxLines = 600
        /// The full-output blob's cap, above the chip's 24-line detail cap.
        public static let fullOutputMaxLines = 400
        /// Invocation blocks hard-wrap at exactly 80 CHARACTERS — no word
        /// boundaries.
        public static let callWrapCols = 80

        /// `2 + 38n`. Analytic, never measured.
        public static func chipsHeight(_ n: Int) -> CGFloat {
            n == 0 ? 0 : topPad + rowHeight * CGFloat(n)
        }

        /// An Output/Stats detail body's height: separator + rows + padding.
        /// `extraRows` carries the counted-tail line when truncated.
        public static func lineDetailHeight(lines: Int, extraRows: Int = 0) -> CGFloat {
            detailSeparator + CGFloat(lines + extraRows) * outputLineHeight + outputBodyPad
        }
    }

    // MARK: - Diff body (spec 06 §2)

    /// lint:allow namespace-enum, namespace-type — constant table (plan §1.4).
    public enum Diff {
        public static let lineHeight: CGFloat = 21
        public static let hunkHeaderHeight: CGFloat = 28
        public static let noticeHeight: CGFloat = 24
        public static let markerWidth: CGFloat = 28
        public static let accentBarWidth: CGFloat = 3
        public static let bodyBottomPad: CGFloat = 8

        public static let textSize: CGFloat = 12
        public static let gutterTextSize: CGFloat = 11
        /// Italic, SANS (not mono) — the one non-mono run in the diff body.
        public static let metaTextSize: CGFloat = 10.5

        /// Both gutters always share this floor.
        public static let gutterMinWidth: CGFloat = 36
        public static let gutterPerDigit: CGFloat = 6.6
        public static let gutterRightPad: CGFloat = 8
        public static let gutterLeftGap: CGFloat = 6
        /// Code column padding after the marker column.
        public static let codePadLeading: CGFloat = 12

        /// The row fill alpha applied to `diffAdd`/`diffDel` (§0.3 C7: stored
        /// translucent, composited at render over whatever ground the body
        /// sits on — the chip card in the transcript, `theme.bg` elsewhere).
        public static let rowWashAlpha = 0.055
        /// The 3 pt accent bar's alpha on a +/− row.
        public static let accentBarAlpha = 0.55
        /// The gutter number on the side that OWNS the change.
        public static let matchingNumberAlpha = 0.9
        /// The other side's number, drawn in `textFaint`.
        public static let faintNumberAlpha = 0.8
        /// The `·` marker on a context row.
        public static let contextMarkerAlpha = 0.5
        /// Un-highlighted code text; a syntax run is full alpha and therefore
        /// slightly brighter.
        public static let codePlainAlpha = 0.92

        public static let addedMarker = "+"
        /// U+2212 MINUS SIGN — not a hyphen.
        public static let deletedMarker = "\u{2212}"
        /// U+00B7 MIDDLE DOT.
        public static let contextMarker = "\u{00B7}"

        /// `max(36, digits × 6.6 + 8 + 6)` where `digits` is the decimal digit
        /// count of the largest line number that actually renders (recomputed
        /// after the 600-line cap). The floor wins through 3 digits.
        public static func gutterWidth(digits: Int) -> CGFloat {
            max(gutterMinWidth, CGFloat(max(digits, 1)) * gutterPerDigit + gutterRightPad + gutterLeftGap)
        }

        /// Digit count of a line number, for ``gutterWidth(digits:)``.
        public static func digitCount(maxLine: Int) -> Int {
            String(max(maxLine, 1)).count
        }

        /// Total left inset before code text: bar + two gutters + marker + pad.
        /// 115.0 for the common 1–3-digit case.
        public static func codeColumnInset(digits: Int) -> CGFloat {
            accentBarWidth + 2 * gutterWidth(digits: digits) + markerWidth + codePadLeading
        }

        /// A diff detail body's analytic height.
        public static func detailHeight(notices: Int, hunks: Int, lines: Int) -> CGFloat {
            Chips.detailSeparator
                + CGFloat(notices) * noticeHeight
                + CGFloat(hunks) * hunkHeaderHeight
                + CGFloat(lines) * lineHeight
                + bodyBottomPad
        }
    }

    // MARK: - Markdown (spec 05)

    /// lint:allow namespace-enum, namespace-type — constant table (plan §1.4).
    public enum Markdown {
        public static let textSize: CGFloat = 14
        /// A FIXED line box, not `.lineSpacing`. `.lineSpacing` adds space
        /// between lines without setting the box, so the first line's ascent is
        /// wrong and every block gap is off by a fraction (plan R7). Use
        /// `NSParagraphStyle.minimum/maximumLineHeight`.
        public static let lineHeight: CGFloat = 22
        public static let blockGap: CGFloat = Transcript.mdBlockGap

        /// Headings are all SEMIBOLD 600 with no color change and no rules.
        public static let h1Size: CGFloat = 19
        public static let h1LineHeight: CGFloat = 27
        public static let h2Size: CGFloat = 16
        public static let h2LineHeight: CGFloat = 24
        public static let h3Size: CGFloat = 15
        public static let h3LineHeight: CGFloat = 22
        /// h4–h6 all share the body size and line height.
        public static let h4Size: CGFloat = 14
        public static let h4LineHeight: CGFloat = 22

        /// Inline bold is 600, never 700 — 700 appears only in table headers.
        public static let boldWeight: CGFloat = 600
        public static let tableHeaderWeight: CGFloat = 700

        /// Inline code: identical size to body, mono, `codeText` over `codeWash`.
        public static let inlineCodeSize: CGFloat = 14
        /// A ROUNDED quad, one per VISUAL LINE a wrapped span covers.
        /// `NSAttributedString.backgroundColor` paints a square box with no
        /// radius and no overhang — use the TextKit 2 segment path (plan R6).
        public static let inlineCodeRadius: CGFloat = 4.5
        public static let inlineCodePadX: CGFloat = 2
        public static let inlineCodeInsetY: CGFloat = 2
        /// The resulting wash box height: 22 − 2 × 2.
        public static let inlineCodeBoxHeight: CGFloat = 18
        /// The bubble's file-mention chip wash uses a 5 pt radius, NOT 4.5.
        public static let mentionChipRadius: CGFloat = 5
        public static let mentionChipPadY: CGFloat = 2

        public static let codeTextSize: CGFloat = 12.5
        public static let codeLineHeight: CGFloat = 18
        public static let codePadX: CGFloat = 12
        public static let codePadY: CGFloat = 10
        public static let codeBlockRadius: CGFloat = 10
        public static let codeHeaderPadY: CGFloat = 5
        /// Measured, not derived.
        public static let codeHeaderBarHeight: CGFloat = 27.5

        public static let copyButtonHeight: CGFloat = 20
        public static let copyPadX: CGFloat = 6
        public static let copyRadius: CGFloat = 5
        public static let copyGap: CGFloat = 4
        public static let copyIconSize: CGFloat = 12
        public static let copyLabelSize: CGFloat = 10.5
        public static let copiedDurationMS = 1200
        /// iOS pins the copy button's plate at `ink(0.08)` instead of fading it
        /// in on hover — a permanently invisible button is unusable by touch.
        public static let copyPlateAlphaTouch = 0.08

        public static let listItemGap: CGFloat = 4
        public static let listMarkerMinWidth: CGFloat = 18
        public static let listMarkerGap: CGFloat = 8
        /// 18 + 8.
        public static let listIndent: CGFloat = 26
        public static let listDiscDiameter: CGFloat = 5
        public static let listDiscLeftMargin: CGFloat = 1
        public static let listMarkerAlpha = 0.85

        public static let quoteRailWidth: CGFloat = 2
        public static let quoteRailAlpha = 0.6
        public static let quoteFillAlpha = 0.05
        /// Only the trailing corners are rounded; the rail edge stays square.
        public static let quoteTrailingRadius: CGFloat = 6
        public static let quotePadLeading: CGFloat = 12
        public static let quotePadTrailing: CGFloat = 10
        public static let quotePadY: CGFloat = 6
        public static let quoteInnerGap: CGFloat = 8

        public static let ruleHeight: CGFloat = 1

        public static let tableCellPadding: CGFloat = 12
        public static let tableDividerWidth: CGFloat = 1
        public static let tableDividerAlpha = 0.10
        public static let tableMinColContent: CGFloat = 48
        public static let tableMinColWidth: CGFloat = 96
    }

    // MARK: - Composer (spec 04 §1)

    /// lint:allow namespace-enum, namespace-type — constant table (plan §1.4).
    public enum Composer {
        /// `pt-4 pb-1` = 16 + 4.
        public static let textareaPadV: CGFloat = 20
        public static let textareaMin: CGFloat = 76
        public static let textareaMax: CGFloat = 260
        /// `pt-1`(4) + `h-8` chips(32) + `pb-2.5`(10).
        public static let actionsRowHeight: CGFloat = 46
        /// 1 pt hairline top + bottom.
        public static let pillBorderV: CGFloat = 2
        /// One-line `py-3`(24) + one 22.75 line + 2 hairline.
        public static let compactTotal: CGFloat = 49
        /// 76 + 46 + 2.
        public static let minHeight: CGFloat = 124
        /// 260 + 46 + 2.
        public static let maxHeight: CGFloat = 308
        /// Below this input width the composer ALWAYS expands.
        public static let minCompactInputWidth: CGFloat = 200
        /// `text-[14px] leading-relaxed` = 14 × 1.625.
        public static let inputLineHeight: CGFloat = 22.75
        public static let inputTextSize: CGFloat = 14
        /// Expanded→compact slack.
        public static let collapseHysteresis: CGFloat = 32
        /// Mode frozen during an interactive resize; re-evaluate at +20 ms.
        public static let resizeSettleMS = 150
        public static let resizeReevaluateMS = 170
        /// Flips within this of a nav SNAP take no morph.
        public static let routeSnapMS = 250
        /// Caret half-period. macOS drives a 2 pt bar at this cadence; iOS uses
        /// the system caret tinted `theme.caret` (plan R11).
        public static let caretBlinkMS = 500
        public static let caretWidth: CGFloat = 2
        /// Send/attach cluster vertical centre delta: 27 pt above the pill
        /// bottom expanded, 24.5 compact.
        public static let clusterYDelta: CGFloat = 2.5
        /// Cluster right inset: `pr-2`(8) compact vs `px-3`(12) expanded.
        public static let clusterXDelta: CGFloat = 4

        public static let pillRadius: CGFloat = 26
        public static let pillBlur: CGFloat = Theme.composerPillBlur
        public static let containerMaxWidth: CGFloat = 768
        public static let containerPadX: CGFloat = 16
        public static let containerPadBottom: CGFloat = 16
        public static let containerGap: CGFloat = 8
        public static let textBoxPadX: CGFloat = 16
        public static let textBoxPadTop: CGFloat = 16
        public static let textBoxPadBottom: CGFloat = 4
        /// The morph eases the top pad 12 → 16.
        public static let textBoxPadTopCompact: CGFloat = 12

        public static let triggerChipHeight: CGFloat = 32
        public static let chipRadius: CGFloat = 8
        public static let chipPadX: CGFloat = 10
        public static let chipGap: CGFloat = 6
        public static let chipIcon: CGFloat = 16

        public static let sendDiameter: CGFloat = 28
        public static let sendGlyph: CGFloat = 14
        /// §0.3 C11: the Stop button is NEUTRAL — a `theme.text` plate with a
        /// `theme.bg` square, not a red one.
        public static let stopSquare: CGFloat = 11
        public static let stopSquareRadius: CGFloat = 3

        public static let attachButton: CGFloat = 28
        public static let attachIcon: CGFloat = 16

        public static let stripThumb: CGFloat = 56
        public static let stripGap: CGFloat = 8
        public static let stripPadTop: CGFloat = 12
        public static let stripPadX: CGFloat = 16
        /// The attachment remove button's offset from the thumb's top-trailing.
        public static let stripRemoveOffset: CGFloat = -6

        public static let slashCardWidth: CGFloat = 380
        public static let slashCardMaxHeight: CGFloat = 280
        public static let slashCardRadius: CGFloat = 12
        public static let slashCardPad: CGFloat = 4
        public static let menuBlur: CGFloat = Theme.menuBlur
        public static let popoverRadius: CGFloat = 12

        public static let footerRowHeight: CGFloat = 20
        public static let footerPadX: CGFloat = 8
        public static let footerGap: CGFloat = 6
        public static let footerTextSize: CGFloat = 12

        /// `clamp(contentHeight + 20, 76, 260) + 46 + 2`, range 124…308.
        /// Fixtures: 1 line → 124, 4 lines → 159, 100 lines → 308.
        public static func totalHeight(contentHeight: CGFloat) -> CGFloat {
            min(max(contentHeight + textareaPadV, textareaMin), textareaMax)
                + actionsRowHeight
                + pillBorderV
        }

        /// `max(1, lineCount) × 22.75` — the input's content height.
        public static func contentHeight(lineCount: Int) -> CGFloat {
            CGFloat(max(1, lineCount)) * inputLineHeight
        }

        /// The pure flip rule (`composer_flip`). Width-driven, not
        /// pointer-driven, so both platforms run it unchanged.
        public static func shouldExpand(
            expanded: Bool,
            textWidth: CGFloat,
            capacity: CGFloat,
            hasNewline: Bool,
            resizing: Bool
        ) -> Bool {
            if hasNewline { return true }
            if resizing { return expanded }
            if capacity < minCompactInputWidth { return true }
            return expanded
                ? textWidth >= capacity - collapseHysteresis
                : textWidth > capacity
        }
    }

    // MARK: - Pickers (spec 08 §1)

    /// lint:allow namespace-enum, namespace-type — constant table (plan §1.4).
    public enum Pickers {
        public static let cardWidth: CGFloat = 360
        public static let cardHeight: CGFloat = 346
        public static let cardRadius: CGFloat = 12

        public static let railWidth: CGFloat = 44
        public static let railPad: CGFloat = 4
        public static let railGap: CGFloat = 4
        public static let railTab: CGFloat = 36
        public static let railTabRadius: CGFloat = 8
        /// A left half-capsule: 3 × 20, inset −4 on the right, 8 from the top.
        public static let railIndicatorWidth: CGFloat = 3
        public static let railIndicatorHeight: CGFloat = 20
        public static let railIndicatorRightInset: CGFloat = -4
        public static let railIndicatorTopInset: CGFloat = 8

        public static let searchRowHeight: CGFloat = 46
        public static let searchPadX: CGFloat = 10
        public static let searchIcon: CGFloat = 14
        public static let searchTextSize: CGFloat = 13

        public static let rowPadX: CGFloat = 8
        public static let rowPadY: CGFloat = 6
        public static let rowRadius: CGFloat = 8
        public static let rowGap: CGFloat = 10
        public static let labelSize: CGFloat = 12.5
        public static let sublineSize: CGFloat = 11
        public static let sublineAlpha = 0.7
        public static let sublineIcon: CGFloat = 11

        public static let kbdChipPadX: CGFloat = 5
        public static let kbdChipPadY: CGFloat = 1
        public static let kbdChipRadius: CGFloat = 5
        public static let kbdChipInkAlpha = 0.05
        public static let kbdChipTextSize: CGFloat = 10
        public static let kbdChipTextAlpha = 0.6

        public static let starToggle: CGFloat = 22
        public static let starRadius: CGFloat = 6
        public static let starIcon: CGFloat = 13

        public static let menuRowPadX: CGFloat = 8
        public static let menuRowPadY: CGFloat = 6
        public static let menuRowRadius: CGFloat = 8
        public static let menuRowGap: CGFloat = 10
        public static let menuRowTextSize: CGFloat = 13

        public static let menuHeadingPadX: CGFloat = 8
        public static let menuHeadingPadTop: CGFloat = 6
        public static let menuHeadingPadBottom: CGFloat = 4
        public static let menuHeadingTextSize: CGFloat = 10
        public static let menuHeadingTextAlpha = 0.6
        /// Uppercase with this tracking.
        public static let menuHeadingTracking: CGFloat = 1.0
    }

    // MARK: - Motion catalog (plan §1.5, spec 07 §1–§2)

    /// One catalog entry: duration + delay + curve.
    public struct MotionSpec: Sendable, Equatable, Hashable {
        public let durationMS: Int
        public let delayMS: Int
        public let curve: SupermuxZeronCubicBezier

        public init(_ durationMS: Int, _ curve: SupermuxZeronCubicBezier, delayMS: Int = 0) {
            self.durationMS = durationMS
            self.delayMS = delayMS
            self.curve = curve
        }

        /// Wall-clock span of the whole timeline, in seconds.
        public var totalDuration: TimeInterval { Double(delayMS + durationMS) / 1000 }

        /// Eased progress for a raw timeline delta (0…1 across ``totalDuration``).
        /// The delay is folded in: progress holds 0 until it has elapsed.
        public func progress(_ rawDelta: Double) -> Double {
            let total = Double(delayMS + durationMS)
            if total <= 0 || durationMS == 0 { return 1 }
            let t = (min(max(rawDelta, 0), 1) * total - Double(delayMS)) / Double(durationMS)
            return curve.eval(min(max(t, 0), 1))
        }

        /// This spec as a SwiftUI `Animation`, for the cases where SwiftUI —
        /// not a hand-driven clock — owns the tween. Anything that must survive
        /// a `LazyVStack` identity churn is hand-driven instead (plan R5).
        public var animation: Animation {
            let base = curve.animation(duration: Double(durationMS) / 1000)
            return delayMS == 0 ? base : base.delay(Double(delayMS) / 1000)
        }
    }

    /// lint:allow namespace-enum, namespace-type — motion catalog (plan §1.5).
    public enum Motion {
        /// Empty-state canvas: opacity 0→1 plus a 4 pt rise.
        /// Violently front-loaded — 97.2 % is done by 250 ms, which is why the
        /// rise reads as "already there" rather than as a slide.
        public static let fadeIn = MotionSpec(500, .easeOutExpo)
        /// Timestamp reveal, composer body mount. Opacity only.
        public static let fadeQuick = MotionSpec(150, .ease)
        /// Popovers. Opacity **0.3 → 1** (NOT 0 — a menu popping in from 0
        /// looks slower) plus a −2 → 0 rise.
        public static let menuIn = MotionSpec(140, .ease)
        /// Opacity 1 → 0 plus 0 → −2; the backdrop blur rides down with it.
        public static let menuOut = MotionSpec(100, .ease)
        /// The jump pill: opacity plus a 2 pt rise.
        public static let dialogIn = MotionSpec(180, .ease)
        /// Fold height tweens — the group body AND the detail card share this
        /// spec and the same click instant, so the row tracks the card's bottom
        /// edge frame-for-frame.
        public static let resize = MotionSpec(200, .easeOut)
        /// The composer flip morph.
        public static let collapse = MotionSpec(180, .easeOut)
        /// Every hover wash.
        public static let hoverFade = MotionSpec(150, .easeTailwind)
        /// Scroll-to-row glide. Fixed duration, **never** a percent of the
        /// remaining distance.
        public static let scrollGlide = MotionSpec(500, .easeInOut)
        /// Skeleton / attachment pulse. Linear phase — the curve is never
        /// evaluated for loaders.
        public static let zeronPulse = MotionSpec(2400, .ease)
        /// The 3×3 working spinner. Linear phase.
        public static let gradientSpin = MotionSpec(750, .ease)

        // MARK: Entrance transforms

        public static let fadeInRise: CGFloat = 4
        public static let menuInRise: CGFloat = -2
        public static let menuInOpacityFloor = 0.3
        public static let dialogInRise: CGFloat = 2
    }

    // MARK: - Pulse clock (spec 07 §5.1, plan R12)

    /// The shared 30 fps loader clock.
    ///
    /// One process-wide epoch, so every cell of every loader in every view is
    /// phase-LOCKED and a spinner that mounts mid-stream joins the wave already
    /// in progress. Each mounted spinner renews a 300 ms lease on every paint;
    /// the tick prunes expired leases and stops entirely when the set empties.
    ///
    /// Do NOT use `withAnimation(.repeatForever)` or `TimelineView(.animation)`:
    /// both pin the render server at the display's native rate — zeron measured
    /// **36 % CPU at 120 Hz for one 10×10 pt spinner**.
    /// lint:allow namespace-enum, namespace-type — constant table (spec 07 §5.1).
    public enum PulseClock {
        /// ~30 fps.
        public static let tickInterval: TimeInterval = 0.033
        /// One lease outlives a few missed frames.
        public static let lease: TimeInterval = 0.300
    }

    /// The pure loader phase math (`crates/proto/src/motion.rs`).
    /// lint:allow namespace-enum, namespace-type — pure phase math (spec 07 §5.2).
    public enum Loaders {
        public static let pulseMinOpacity = 0.08
        public static let pulseMinScale = 0.90
        /// 0.15 s of the 2.4 s period.
        public static let pulseStagger = 0.15 / 2.4
        public static let gspinDim = 0.10
        /// The 3×3 working spinner's cell size in the chat pane.
        public static let matrixCellSize: CGFloat = 2.5
        public static let matrixSide = 3
        /// `3·cell + 2·(cell/2)` = `4·cell` per side ⇒ 10 × 10 pt.
        public static let matrixFootprint: CGFloat = 10

        /// The working trailer row under the last transcript row.
        public static let trailerGap: CGFloat = Theme.spaceSM
        public static let trailerTopPad: CGFloat = 10
        public static let trailerWordSize: CGFloat = 12
        public static let trailerElapsedSize: CGFloat = 11
        /// Flavour words rotate every 7 s, indexed
        /// `words[(fnv1a(sessionKey) + elapsedSecs / 7) % count]`.
        public static let flavourRotateSecs = 7

        /// Always in `[0, 1)` — `rem_euclid`, not `truncatingRemainder`.
        public static func staggeredPhase(_ rawDelta: Double, index: Int, stagger: Double) -> Double {
            let v = (rawDelta - Double(index) * stagger).truncatingRemainder(dividingBy: 1)
            return v < 0 ? v + 1 : v
        }

        /// 0 at phase 0, 1 at 0.5, 0 at 1.
        public static func pulseWave(_ phase: Double) -> Double {
            0.5 - 0.5 * cos(phase * 2 * .pi)
        }

        /// 0.08 → 1 → 0.08.
        public static func pulseOpacity(_ phase: Double) -> Double {
            pulseMinOpacity + (1 - pulseMinOpacity) * pulseWave(phase)
        }

        /// 0.90 → 1 → 0.90.
        public static func pulseScale(_ phase: Double) -> Double {
            pulseMinScale + (1 - pulseMinScale) * pulseWave(phase)
        }

        /// The working spinner's per-cell opacity. **Piecewise LINEAR** in each
        /// segment — a direct port of the CSS `gradient-spin-pulse` keyframes.
        /// Do not smooth it: the flat 45 %→92 % rest band is what makes the
        /// wave read as a travelling pulse rather than a sine breathe.
        public static func gspinOpacity(_ t0: Double, dim: Double = gspinDim) -> Double {
            var t = t0.truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            if t < 0.45 { return 1 + (dim - 1) * (t / 0.45) }
            if t < 0.92 { return dim }
            return dim + (1 - dim) * ((t - 0.92) / 0.08)
        }

        /// The 3×3 wave's per-cell phase offset. The pulse enters at the bottom
        /// edge and converges on the top-centre cell, so it reads as travelling
        /// UPWARD: bottom-centre leads at 0, the top corners trail at 0.75.
        public static func matrixCellPhase(row: Int, col: Int) -> Double {
            let centre = Double(matrixSide - 1) / 2
            let maxD = Double(matrixSide - 1) + centre
            let d = Double(matrixSide - 1 - row) + abs(Double(col) - centre)
            return d / (maxD + 1)
        }

        /// The loading-attachment breathe: a 2.4 s cosine between 0.35 and 0.75
        /// with no per-cell stagger.
        public static func skeletonOpacity(_ phase: Double) -> Double {
            0.35 + 0.4 * pulseWave(phase)
        }
    }

    // MARK: - Stick spring (spec 07 §3)

    /// The transcript's stick-to-bottom spring constants.
    ///
    /// The integrator itself lives in `Motion/SupermuxZeronStickSpring.swift`.
    /// Sign convention: larger offset = closer to the bottom.
    /// lint:allow namespace-enum, namespace-type — constant table (spec 07 §3).
    public enum Spring {
        /// Retains velocity frame-to-frame (higher = more glide).
        public static let damping = 0.7
        /// Pull toward the target (higher = snappier).
        public static let stiffness = 0.05
        /// Inertia (higher = slower to start/stop).
        public static let mass = 1.25
        /// The fixed-timestep reference frame, in milliseconds.
        public static let frameMS = 1000.0 / 60.0
        /// Cap on simulated frames per tick — a hitch catches up instead of
        /// teleporting. Applied by the CALLER, not inside `step`.
        public static let maxCatchupFrames = 8.0
        /// EMA rate for the feed-forward target-growth estimate.
        public static let growthEMA = 0.12
        /// While streaming, chase up to this many points ABOVE the true bottom.
        /// This is why the viewport rides ~16 px high mid-stream, and why the
        /// inverted/rotated-list shortcut cannot represent this design.
        public static let chaseMaxLead = 32.0
        /// The multiplier on the smoothed growth rate that produces the chase.
        public static let chaseGrowthGain = 9.0
        /// Treat as exactly pinned within this distance of the bottom.
        public static let atBottomPX = 2.0
        /// Keep the loop warm this long after landing so a streaming pause
        /// resumes at cruise instead of re-accelerating from zero.
        public static let settleGraceMS = 500.0
        /// Teleport when farther than this many viewports from the end; glide
        /// the rest.
        public static let glideMaxViewports = 2.5
        /// Re-engage band. Direction-aware: restick only when the distance is
        /// inside the band AND shrinking, or the pin becomes unbreakable.
        public static let stickThresholdPX = 70.0
        /// The jump-to-bottom pill's show threshold.
        public static let jumpThresholdPX = 320.0
        /// List overdraw beyond the viewport.
        public static let overdrawPX = 320.0
        /// mugen's settle thresholds.
        public static let idleVelocityThreshold = 0.05
        /// The spring snaps exactly once within this error.
        public static let snapEpsilonPX = 0.5
        /// Hysteresis on the escape test, suppressing jitter.
        public static let escapeHysteresisPX = 1.0
        /// Backend doc-commit coalescing window — the cadence the feed-forward
        /// term exists to smooth into a continuous glide.
        public static let streamCommitMS = 120.0
    }

    /// The own-send entry glide (spec 07 §3.6).
    /// lint:allow namespace-enum, namespace-type — constant table (spec 07 §3.6).
    public enum OwnSend {
        /// Where a freshly-sent prompt rests below the viewport top
        /// (titlebar 38 + 10 pt of breathing room). **Zero when the anchor is
        /// row 0** — row 0 already carries the titlebar chrome inside its box.
        public static let topInset: CGFloat = 48
        /// Epsilon of extra height under the reservation. NOT scroll room: 24
        /// pt of it read as a janky overshoot-and-fight zone.
        public static let scrollSlack: CGFloat = 2
        /// Per-60fps-frame fraction of remaining travel RETAINED — an
        /// exponential ease-out, ~90 % covered in ~230 ms.
        public static let glideRetain = 0.85
        /// The glide snaps to the absolute hold within this error.
        public static let glideSnapPX = 1.0
        /// Rounding tolerance added to `scrollSlack` in the drift test.
        public static let driftTolerancePX = 2.0
    }

    /// The fold tween's arming window (spec 07 §2.5, plan R5).
    ///
    /// A tool-group fold animates its height ONLY while
    /// `now - toggledAt < 400 ms`; past that it renders at its static height.
    /// In a virtualized list an armed tween replays on every remount — i.e.
    /// every scroll-back — so a once-collapsed group flashed open→closed each
    /// time it reappeared. Auto-open (streaming) and content growth NEVER
    /// tween; only the `open` toggle does.
    /// lint:allow namespace-enum, namespace-type — constant table (spec 07 §2.5).
    public enum Fold {
        /// "The RESIZE spec's 200 ms plus margin."
        public static let tweenWindowMS = 400.0
    }

    /// The streaming fade veil (spec 07 §5.7).
    ///
    /// Opacity only — zero translate. Layout commits instantly; the veil is
    /// purely cosmetic. A chunk fades exactly once; already-faded text never
    /// re-animates, and rows present at (re)attach are SEEDED so switching back
    /// to a streaming session does not dissolve the whole reply.
    /// lint:allow namespace-enum, namespace-type — pure fade math (spec 07 §5.7).
    public enum Veil {
        public static let emaSeedMS = 160.0
        public static let minFadeMS = 120.0
        public static let maxFadeMS = 400.0
        public static let curvePow = 1.6
        public static let gapClampMS = 1000.0
        /// EMA retention of the previous cadence sample.
        public static let emaRetain = 0.7
        /// 3+ concurrent chunks speed each other up by 30 %.
        public static let boostPerExtraChunk = 0.3
        public static let boostFreeChunks = 2
        /// Fixed at chunk arrival: `clamp(ema × 3, 120, 400)`.
        public static let durationGain = 3.0

        /// `1 − (1 − p)^1.6`.
        public static func opacity(_ p: Double) -> Double {
            1 - pow(1 - min(max(p, 0), 1), curvePow)
        }

        /// `clamp(ema × 3, 120, 400)`, in milliseconds.
        public static func duration(ema: Double) -> Double {
            min(max(ema * durationGain, minFadeMS), maxFadeMS)
        }

        /// `1 + 0.3 · max(0, n − 2)`.
        public static func boost(chunks: Int) -> Double {
            1 + boostPerExtraChunk * Double(max(0, chunks - boostFreeChunks))
        }

        /// `ema × 0.7 + min(gap, 1000) × 0.3`.
        public static func nextEMA(_ ema: Double, gapMS: Double) -> Double {
            ema * emaRetain + min(gapMS, gapClampMS) * (1 - emaRetain)
        }
    }
}

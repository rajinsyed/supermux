//
//  SupermuxZeronDiffBody.swift
//  SupermuxZeronUI
//
//  The inline diff body an expanded tool chip renders. Spec 06, spec 03 §4.4.
//
//  This is deliberately the SAME component a changes pane would use: zeron's
//  comment is that "an inline tool diff is indistinguishable from the checkout
//  diff sidebar", and every constant here comes from `changes.rs`, not from a
//  transcript-specific table.
//
//  ── Row anatomy (left → right), spec 06 §2.2 ──
//
//      [3 pt accent bar][old gutter][new gutter][28 pt marker][12 pt pad][code]
//
//  Both gutters always share one width, computed per file from the largest line
//  number that actually renders. Context rows still paint the accent-bar column
//  as an invisible spacer, so the five columns stay aligned across kinds.
//
//  ── What is deliberately absent ──
//
//  No hover, no press, no selection, no tap target, no horizontal scroll, no
//  intra-line (word-level) diffing, and no animation. `diff_line_row` has no
//  `.id()`, no mouse handler and no `.hover()` in the source; the only motion
//  anywhere near a diff is the enclosing card's height tween.
//
//  ── The composite ground (§0.3 C7) ──
//
//  Row washes are stored TRANSLUCENT (`diffAdd @ 0.055`) and composited at
//  render, because a transcript diff sits on the `ink(0.03)` chip card while a
//  changes pane would sit on `theme.bg`. One baked hex cannot serve both.
//

public import CoreGraphics
public import SwiftUI

public import SupermuxClaudeHarness

// MARK: - Syntax highlights

/// Paint-only syntax runs for one diff, indexed by side and 1-based line
/// number.
///
/// Highlighting changes **foreground color only** — never font, weight, style,
/// wrapping, height or scroll geometry (plan R9). The body therefore renders
/// identically before highlights arrive, and a later recolor causes no relayout;
/// that "plain first, colored a frame later" behaviour is faithful, not a
/// defect.
public struct SupermuxZeronDiffHighlights: Sendable, Equatable {
    /// One colored run over a line, in UTF-8 BYTE offsets (tree-sitter's own).
    public struct Span: Sendable, Equatable, Hashable {
        public let start: Int
        public let end: Int
        public let kind: SupermuxZeronHighlightKind

        public init(start: Int, end: Int, kind: SupermuxZeronHighlightKind) {
            self.start = start
            self.end = end
            self.kind = kind
        }
    }

    /// Spans of the OLD document, keyed by 1-based line number.
    public let old: [Int: [Span]]
    /// Spans of the NEW document, keyed by 1-based line number.
    public let new: [Int: [Span]]

    public init(old: [Int: [Span]] = [:], new: [Int: [Span]] = [:]) {
        self.old = old
        self.new = new
    }

    /// Which document a line is highlighted against (spec 06 §4.1):
    /// deletions read `old`, additions read `new`, and context prefers `new`
    /// when a new document exists.
    ///
    /// The side is chosen FIRST and then read — a context line that resolves to
    /// the new document and finds nothing there paints plain, it does not fall
    /// back to the old document (`DiffHighlights::source_ref`, changes.rs:115).
    /// Falling back would colour the line against a document whose text at that
    /// number is a different line.
    public func spans(for line: SupermuxHarnessDiff.Line) -> [Span] {
        switch line.kind {
        case .deletion:
            return line.oldNumber.flatMap { old[$0] } ?? []
        case .addition:
            return line.newNumber.flatMap { new[$0] } ?? []
        case .context:
            if !new.isEmpty, let number = line.newNumber { return new[number] ?? [] }
            return line.oldNumber.flatMap { old[$0] } ?? []
        }
    }
}

// MARK: - The body

/// The stacked diff body: notices, then each hunk's header and lines, then the
/// 8 pt bottom pad. Height is exactly
/// `notices·24 + hunks·28 + lines·21 + 8`.
public struct SupermuxZeronDiffBody: View {
    private typealias Diff = SupermuxZeronMetrics.Diff

    private let diff: SupermuxHarnessDiff
    private let theme: SupermuxZeronTheme
    private let highlights: SupermuxZeronDiffHighlights?
    private let gutterWidth: CGFloat

    public init(
        diff: SupermuxHarnessDiff,
        theme: SupermuxZeronTheme,
        highlights: SupermuxZeronDiffHighlights? = nil
    ) {
        self.diff = diff
        self.theme = theme
        self.highlights = highlights
        self.gutterWidth = Diff.gutterWidth(digits: Diff.digitCount(maxLine: Self.maxLine(diff)))
    }

    /// The largest line number appearing on EITHER side of what actually
    /// renders. Recomputed post-truncation, so the gutter fits the survivors.
    static func maxLine(_ diff: SupermuxHarnessDiff) -> Int {
        var maximum = 0
        for hunk in diff.hunks {
            for line in hunk.lines {
                maximum = max(maximum, line.oldNumber ?? 0, line.newNumber ?? 0)
            }
        }
        return maximum
    }

    /// The body's painted height — the analytic value, excluding the chip's
    /// separator hairline.
    public static func bodyHeight(of diff: SupermuxHarnessDiff) -> CGFloat {
        CGFloat(diff.notices.count) * Diff.noticeHeight
            + CGFloat(diff.hunks.count) * Diff.hunkHeaderHeight
            + CGFloat(diff.lineCount) * Diff.lineHeight
            + Diff.bodyBottomPad
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Notices render at the TOP of the body, above every hunk — the
            // truncation notice included.
            ForEach(Array(diff.notices.enumerated()), id: \.offset) { _, notice in
                SupermuxZeronDiffNoticeRow(notice: notice, theme: theme)
            }
            ForEach(diff.hunks) { hunk in
                SupermuxZeronDiffHunkHeaderRow(hunk: hunk, theme: theme)
                ForEach(hunk.lines) { line in
                    SupermuxZeronDiffLineRow(
                        line: line,
                        theme: theme,
                        gutterWidth: gutterWidth,
                        spans: highlights?.spans(for: line) ?? []
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Diff.bodyBottomPad)
        .clipped()
    }
}

// MARK: - Notice row

/// A 24 pt full-width meta row: "New file", the truncation notice, etc.
/// **Sans**, 11 pt, `textFaint`, no background.
struct SupermuxZeronDiffNoticeRow: View {
    private typealias Diff = SupermuxZeronMetrics.Diff

    let notice: String
    let theme: SupermuxZeronTheme

    var body: some View {
        Text(notice)
            .font(SupermuxZeronFonts.sans(size: Diff.gutterTextSize))
            .foregroundStyle(theme.textFaint)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, SupermuxZeronMetrics.Theme.spaceLG)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Diff.noticeHeight)
    }
}

// MARK: - Hunk header row

/// The 28 pt `@@ -a,b +c,d @@` row on the bluish `diffHunkBG` wash.
///
/// The header text is synthesized rather than carried: a transcript diff is
/// built from a structured patch, so there is never a trailing function-context
/// string on it.
struct SupermuxZeronDiffHunkHeaderRow: View {
    private typealias Diff = SupermuxZeronMetrics.Diff

    let hunk: SupermuxHarnessDiff.Hunk
    let theme: SupermuxZeronTheme

    /// `"@@ -{oldStart},{oldLen} +{newStart},{newLen} @@"`, where each length is
    /// the count of lines that side actually contributes (context + its own
    /// kind) — matching `similar`'s grouped-op ranges.
    static func header(for hunk: SupermuxHarnessDiff.Hunk) -> String {
        var oldLen = 0
        var newLen = 0
        for line in hunk.lines {
            switch line.kind {
            case .addition: newLen += 1
            case .deletion: oldLen += 1
            case .context:
                oldLen += 1
                newLen += 1
            }
        }
        return "@@ -\(hunk.oldStart),\(oldLen) +\(hunk.newStart),\(newLen) @@"
    }

    var body: some View {
        Text(Self.header(for: hunk))
            .font(SupermuxZeronFonts.mono(size: Diff.gutterTextSize))
            .foregroundStyle(theme.textFaint)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, SupermuxZeronMetrics.Theme.spaceLG)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Diff.hunkHeaderHeight)
            .background(theme.diffHunkBG)
    }
}

// MARK: - Line row

/// One 21 pt diff line: accent bar, dual gutters, marker, code.
struct SupermuxZeronDiffLineRow: View {
    private typealias Diff = SupermuxZeronMetrics.Diff

    let line: SupermuxHarnessDiff.Line
    let theme: SupermuxZeronTheme
    let gutterWidth: CGFloat
    let spans: [SupermuxZeronDiffHighlights.Span]

    var body: some View {
        HStack(spacing: 0) {
            // Rendered on EVERY kind — a context row's bar is an invisible
            // spacer, which is what keeps the five columns aligned.
            Rectangle()
                .fill(accentBar)
                .frame(width: Diff.accentBarWidth)
                .frame(maxHeight: .infinity)

            gutter(number: line.oldNumber, color: oldNumberColor)
            gutter(number: line.newNumber, color: newNumberColor)

            Text(marker)
                .font(SupermuxZeronFonts.mono(size: Diff.textSize))
                .foregroundStyle(markerColor)
                .frame(width: Diff.markerWidth)

            code
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Diff.lineHeight)
        .background(rowWash)
    }

    /// A gutter cell: right-aligned inside its width, 8 pt of trailing pad
    /// baked into that width. An absent number is an EMPTY string, never a dash.
    private func gutter(number: Int?, color: Color) -> some View {
        Text(number.map(String.init) ?? "")
            .font(SupermuxZeronFonts.mono(size: Diff.gutterTextSize))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: max(0, gutterWidth - Diff.gutterRightPad), alignment: .trailing)
            .padding(.trailing, Diff.gutterRightPad)
    }

    /// The code column. **Hard clip, no ellipsis, no wrap, no h-scroll** —
    /// gpui's `.truncate()` is deliberately not used here, so a long line is
    /// simply cut by the card's own clip.
    ///
    /// `fixedSize` is what suppresses the ellipsis (`.lineLimit(1)` alone would
    /// add one), but it also reports the line's FULL intrinsic width upward:
    /// a 400-char line measured an ideal width of ~2995 pt, which a transcript
    /// row that sizes to `fittingSize` would honour — a chat pane three
    /// thousand points wide. `idealWidth: 0` caps what propagates while
    /// `maxWidth: .infinity` still lets the column fill, exactly reproducing
    /// gpui's `flex_1().min_w_0().overflow_hidden()`.
    private var code: some View {
        Text(attributedCode)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Diff.codePadLeading)
            .clipped()
    }

    /// One `AttributedString` with the font set ONCE and only `.foregroundColor`
    /// varying per run.
    ///
    /// Concatenating `Text` views with `+` would let shaping differ at run
    /// boundaries, which breaks the "highlighting never changes layout"
    /// contract. Byte offsets are converted through `String.UTF8View` and any
    /// span that does not land on a scalar boundary is DROPPED rather than
    /// trapped on — gpui tolerates a bad offset, `AttributedString` would not.
    private var attributedCode: AttributedString {
        var string = AttributedString(line.text)
        string.font = SupermuxZeronFonts.mono(size: Diff.textSize)
        string.foregroundColor = theme.text.opacity(Diff.codePlainAlpha)
        guard !spans.isEmpty else { return string }

        let utf8 = line.text.utf8
        let palette = theme.syntax
        for span in spans {
            guard span.start >= 0, span.end > span.start, span.end <= utf8.count else { continue }
            guard
                let lower = utf8.index(utf8.startIndex, offsetBy: span.start, limitedBy: utf8.endIndex),
                let upper = utf8.index(utf8.startIndex, offsetBy: span.end, limitedBy: utf8.endIndex),
                let from = AttributedString.Index(lower, within: string),
                let to = AttributedString.Index(upper, within: string),
                from < to
            else { continue }
            string[from ..< to].foregroundColor = palette.color(for: span.kind)
        }
        return string
    }

    // MARK: Per-kind paint

    private var marker: String {
        switch line.kind {
        case .addition: Diff.addedMarker
        case .deletion: Diff.deletedMarker
        case .context: Diff.contextMarker
        }
    }

    /// The marker glyph is FULL alpha on +/− rows; only context is dimmed.
    private var markerColor: Color {
        switch line.kind {
        case .addition: theme.diffAdd
        case .deletion: theme.diffDel
        case .context: theme.textFaint.opacity(Diff.contextMarkerAlpha)
        }
    }

    /// A context row paints nothing — `ink(0)`, never `Color.clear`, so a
    /// cross-fade over it cannot flash grey.
    private var rowWash: Color {
        switch line.kind {
        case .addition: theme.diffAddWash()
        case .deletion: theme.diffDelWash()
        case .context: theme.ink(0)
        }
    }

    private var accentBar: Color {
        switch line.kind {
        case .addition: theme.diffAdd.opacity(Diff.accentBarAlpha)
        case .deletion: theme.diffDel.opacity(Diff.accentBarAlpha)
        case .context: theme.ink(0)
        }
    }

    /// Only the gutter MATCHING the row's kind takes the tinted color; the
    /// other side always falls back to the faint tone (spec 06 §2.4).
    private var oldNumberColor: Color {
        line.kind == .deletion
            ? theme.diffDel.opacity(Diff.matchingNumberAlpha)
            : theme.textFaint.opacity(Diff.faintNumberAlpha)
    }

    private var newNumberColor: Color {
        line.kind == .addition
            ? theme.diffAdd.opacity(Diff.matchingNumberAlpha)
            : theme.textFaint.opacity(Diff.faintNumberAlpha)
    }
}

//
//  SupermuxZeronCodeBlock.swift
//  SupermuxZeronUI
//
//  The fenced code block: container, language header bar, copy button, and the
//  per-line 18 pt body. Spec 05 §2.5, `render.rs:1001-1154`.
//
//  ── The height identity ──
//
//  Height is exactly `lines × 18 + 2 × 10 + header`. Code NEVER WRAPS, so the
//  height is width-independent — and because every line is its own fixed 18 pt
//  row, the block's height is final BEFORE highlighting arrives and cannot move
//  when it does. That is the whole reason the syntax invariant is expressible.
//
//  ── Not selectable, on purpose ──
//
//  zeron builds bare styled text per line and never registers a code line with
//  the selection registry (`render.rs:1147`, spec 05 §6.7): **code blocks are
//  not selectable and the copy button is the only way to get code out.** That
//  is reproduced here — no `.textSelection(.enabled)` on the body — and it is
//  also what makes this port's per-block-selection deviation (R8) cost nothing
//  for code.
//

public import SwiftUI

internal import Foundation

/// A fenced code block.
public struct SupermuxZeronCodeBlock: View {
    private typealias Md = SupermuxZeronMetrics.Markdown

    private let language: String?
    private let code: String
    private let theme: SupermuxZeronTheme
    /// Veil spans over the WHOLE code text; each line slices its own window out
    /// of them, so a fading append dissolves per line without disturbing the
    /// exact `lines × 18` height.
    private let veilSpans: [SupermuxZeronVeilSpan]
    /// `nil` while the highlighter is still pending — the block renders plain
    /// and recolours in place, with zero layout change.
    private let highlight: [[SupermuxZeronHighlightSpan]]?

    @State private var copiedAt: Date?
    @State private var isHoveringCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        language: String?,
        code: String,
        theme: SupermuxZeronTheme,
        veilSpans: [SupermuxZeronVeilSpan] = [],
        highlight: [[SupermuxZeronHighlightSpan]]? = nil
    ) {
        self.language = language
        self.code = code
        self.theme = theme
        self.veilSpans = veilSpans
        self.highlight = highlight
    }

    /// The block's exact height. Analytic — never measured.
    public static func height(lineCount: Int, hasLanguage: Bool) -> CGFloat {
        CGFloat(lineCount) * Md.codeLineHeight
            + 2 * Md.codePadY
            + (hasLanguage ? Md.codeHeaderBarHeight + 1 : 0)
    }

    private var lines: [String] { code.components(separatedBy: "\n") }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Rendered ONLY when the fence carries an info string. A bare
            // ``` fence and an indented block have NO header — the body's
            // 10 pt top padding starts under the container's border.
            if let language, !language.isEmpty {
                header(language)
            }
            body(for: lines)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Faint white wash over the near-black panel, with the hairline border.
        .background(theme.ink(0.035))
        .clipShape(RoundedRectangle(cornerRadius: Md.codeBlockRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Md.codeBlockRadius, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        }
        // Overlaid LAST so it paints above header and body, and absolutely so
        // the "Copied" flash NEVER shifts layout.
        .overlay(alignment: .topTrailing) { copyButton }
    }

    // MARK: Header

    private func header(_ language: String) -> some View {
        // The label is the raw first token of the info string, VERBATIM — not
        // title-cased, not uppercased. And it is SANS, not mono: the mono
        // family is applied to the body only.
        Text(language)
            .font(SupermuxZeronFonts.sans(size: 11))
            .foregroundStyle(theme.textMuted)
            .lineLimit(1)
            .frame(height: Md.codeHeaderBarHeight, alignment: .leading)
            .padding(.horizontal, Md.codePadX)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A whisper of tone separation, stacked ON TOP of the container's
            // ink(0.035) — the two compose to #141414 in dark.
            .background(theme.ink(0.02))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.border).frame(height: 1)
            }
    }

    // MARK: Body

    private func body(for lines: [String]) -> some View {
        // Long lines SCROLL; they never wrap.
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    // Each line is its OWN fixed 18 pt row. The pitch comes
                    // entirely from that height, never from a stack spacing.
                    codeLine(line, at: index)
                        .frame(height: Md.codeLineHeight, alignment: .leading)
                }
            }
            .padding(.horizontal, Md.codePadX)
            .padding(.vertical, Md.codePadY)
        }
    }

    private func codeLine(_ line: String, at index: Int) -> some View {
        let spans = highlight?.indices.contains(index) == true ? highlight![index] : []
        // FULL-strength `theme.text`. The 0.92 dimming belongs to the DIFF pane
        // only: `changes.rs:2726` calls `runs_for_syntax_line_with_plain(…,
        // theme.text.opacity(0.92), …)`, while a markdown fence goes through
        // `runs_for_syntax_line` (`render.rs:1172`), which passes `theme.text`
        // undimmed. Pixel-verified in `fade-timestamp/02-after.png`: the code
        // body's glyphs sample (229,229,229) = #E5E5E5 = `theme.text`, not the
        // #D4D4D4 that 0.92 would produce.
        let plain = theme.text
        let runs = SupermuxZeronSyntaxRuns.runs(
            line: line,
            spans: spans,
            palette: theme.syntax,
            plainColor: plain
        )
        let local = SupermuxZeronRowVeil.slice(
            veilSpans,
            from: lineByteStart(index),
            to: lineByteStart(index) + line.utf8.count
        )
        return SupermuxZeronCodeLineText(
            line: line,
            runs: runs,
            plainColor: plain,
            veilSpans: local
        )
    }

    /// The byte offset of a line's start in the whole code text — `+1` per line
    /// for the `\n` the split consumed.
    private func lineByteStart(_ index: Int) -> Int {
        var offset = 0
        for i in 0..<index { offset += lines[i].utf8.count + 1 }
        return offset
    }

    // MARK: Copy button

    private var isCopied: Bool {
        guard let copiedAt else { return false }
        return Date().timeIntervalSince(copiedAt) < Double(Md.copiedDurationMS) / 1000
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            HStack(spacing: Md.copyGap) {
                SupermuxZeronIcon(isCopied ? .check : .copy, size: Md.copyIconSize)
                    // The check does NOT turn green: `text_muted` in both states.
                    .foregroundStyle(theme.textMuted)
                if isCopied {
                    Text(Self.copiedLabel)
                        .font(SupermuxZeronFonts.sans(size: Md.copyLabelSize))
                        .foregroundStyle(theme.textMuted)
                }
            }
            .padding(.horizontal, Md.copyPadX)
            .frame(height: Md.copyButtonHeight)
            .background(copyPlate)
            .clipShape(RoundedRectangle(cornerRadius: Md.copyRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Measured from the container's PADDING BOX: 3 pt below and 5 pt inside
        // the border. Deliberately NOT "centered" — its 20 pt box at top 3
        // inside a 27.5 pt bar sits 0.75 pt high, and that offset is the design.
        .padding(.top, 3)
        .padding(.trailing, 5)
        #if os(macOS)
        .onHover { isHoveringCopy = $0 }
        .animation(
            reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
            value: isHoveringCopy
        )
        #endif
        .accessibilityLabel(Self.copyAccessibilityLabel)
    }

    /// The plate. On macOS it rests fully transparent and fades to `ink(0.08)`
    /// on hover; on iOS it is PINNED at `ink(0.08)` — a permanently invisible
    /// button is unusable by touch (plan §4).
    ///
    /// Note the resting value is `ink(0)`, white-at-zero-alpha, and never
    /// `Color.clear`: a fade through `clear` flashes grey mid-transition.
    private var copyPlate: Color {
        #if os(macOS)
        return theme.ink(isHoveringCopy ? Md.copyPlateAlphaTouch : 0)
        #else
        return theme.ink(Md.copyPlateAlphaTouch)
        #endif
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = code
        #endif
        copiedAt = Date()
        // The label reverts after exactly 1200 ms. Because the button is an
        // overlay, its appearance and disappearance never reflow the block.
        let deadline = Double(Md.copiedDurationMS) / 1000
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Md.copiedDurationMS))
            if let copiedAt, Date().timeIntervalSince(copiedAt) >= deadline {
                self.copiedAt = nil
            }
        }
    }

    private static let copiedLabel = String(
        localized: "supermux.zeron.markdown.copied",
        defaultValue: "Copied",
        bundle: .module,
        comment: "Confirmation shown for 1.2s after copying a code block."
    )

    private static let copyAccessibilityLabel = String(
        localized: "supermux.zeron.markdown.copyCode",
        defaultValue: "Copy code",
        bundle: .module,
        comment: "Accessibility label for the code block's copy button."
    )
}

// MARK: - One code line

/// One fixed-height code line.
///
/// Built by concatenating per-run `Text` values rather than through TextKit:
/// a code line never wraps and carries no inline-code wash, so it needs neither
/// of the two things `SupermuxZeronTextKitRenderer` exists for. Its 18 pt box
/// is enforced by the row's `.frame(height:)`, exactly as the Rust's
/// `div().h(px(18.0))` does.
private struct SupermuxZeronCodeLineText: View {
    let line: String
    let runs: [SupermuxZeronTextRun]
    let plainColor: Color
    let veilSpans: [SupermuxZeronVeilSpan]

    var body: some View {
        // An interior blank line renders as an empty 18 pt row, which the
        // parent frame already provides.
        if runs.isEmpty {
            Color.clear.frame(width: 0)
        } else {
            veiled
                .font(SupermuxZeronFonts.mono(size: SupermuxZeronMetrics.Markdown.codeTextSize))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The runs concatenated, each carrying its own colour × veil alpha.
    private var veiled: Text {
        var offset = 0
        var out = Text("")
        for run in runs {
            let alpha = SupermuxZeronRowVeil.opacity(at: offset, in: veilSpans)
            out = out + Text(run.text).foregroundColor(run.color.opacity(alpha))
            offset += run.byteLength
        }
        return out
    }
}

//
//  SupermuxZeronTextKitRenderer.swift
//  SupermuxZeronUI
//
//  The `NSTextLayoutManager` (TextKit 2) host. This file exists for two reasons
//  and BOTH are mandatory (plan R6, R7).
//
//  ── R6: the inline-code wash ──
//
//  zeron's inline code sits on a 4.5 pt ROUNDED quad with `padX 2` /
//  `insetY 2`, and a wrapped span gets ONE BOX PER VISUAL LINE, each with its
//  own 2 pt horizontal overhang (`render.rs:920` `range_rects`).
//  `NSAttributedString.backgroundColor` paints a SQUARE box with no radius and
//  no overhang — the exact limitation `render.rs:492-494` calls out — and spec
//  05 §9.1 calls the rounded wash "the most recognizable detail in the design".
//  `enumerateTextSegments(in:type:.standard)` returns one rect per visual line,
//  which is precisely the geometry `range_rects` computes by binary search.
//
//  ── R7: fixed 22 pt line boxes ──
//
//  gpui's `.line_height(px(22))` is an ABSOLUTE line box. SwiftUI's
//  `.lineSpacing()` adds space BETWEEN lines and leaves the first line's ascent
//  wrong, so a single-line bubble comes out at 41 or 43 pt instead of exactly
//  42 and the 12 pt block gap reads as 11 or 13. `NSParagraphStyle`'s
//  `minimumLineHeight == maximumLineHeight` sets the box. Verified on this
//  toolchain: a 14 pt face whose natural line height is 17.0 lays out at
//  exactly 22.0 with the pin, and the segment rects are 22.0 tall.
//
//  ── Why the wash is drawn, not attributed ──
//
//  Everything here is PAINT. The layout is computed once per (text, width) and
//  the veil only rewrites foreground colors, which — with the font unchanged —
//  does not invalidate layout. That is what makes the streaming fade free.
//
//  ── Selection (R8, accepted v1 deviation) ──
//
//  zeron rebuilt cross-block selection by hand: a document-ordered registry
//  populated during paint plus window-level mouse listeners
//  (`markdown/selection.rs` + `render.rs:679-913`). This port ships PER-BLOCK
//  selection instead — a drag cannot span a heading and the paragraph under it,
//  and ⌘C over a multi-block answer copies one block. The registry port is a
//  workstream of its own. Note the compensating zeron behavior that IS
//  reproduced: code blocks are not selectable at all, so the copy button is the
//  only extraction path there and that half costs nothing.
//

public import SwiftUI

internal import CoreGraphics
internal import Foundation

#if canImport(AppKit)
internal import AppKit
#elseif canImport(UIKit)
internal import UIKit
#endif

// MARK: - Attributed text model

/// One styled run of inline text, resolved to concrete paint values.
///
/// This is the Swift form of gpui's `TextRun` after `flatten_runs_weighted`:
/// the font family/weight/style are decided, the color is resolved, and the
/// link and strikethrough decorations are attached.
public struct SupermuxZeronTextRun: Sendable, Equatable {
    /// Length in UTF-8 BYTES — the unit the veil tracks.
    public var byteLength: Int
    public var text: String
    public var isMono: Bool
    public var weight: SupermuxZeronFontWeight
    public var isItalic: Bool
    public var color: Color
    /// A link's destination, or `nil`. The pending-link sentinel is kept as a
    /// destination for STYLING and stripped for clickability by the builder.
    public var link: String?
    public var isStrikethrough: Bool

    public init(
        text: String,
        isMono: Bool = false,
        weight: SupermuxZeronFontWeight = .regular,
        isItalic: Bool = false,
        color: Color,
        link: String? = nil,
        isStrikethrough: Bool = false
    ) {
        self.text = text
        self.byteLength = text.utf8.count
        self.isMono = isMono
        self.weight = weight
        self.isItalic = isItalic
        self.color = color
        self.link = link
        self.isStrikethrough = isStrikethrough
    }
}

/// A flattened block of inline text: one string, its runs, its clickable link
/// ranges, and its inline-code ranges.
///
/// The inline-code ranges are separate from the runs because their wash is
/// painted by an underlay, not by a run attribute (see the file header).
public struct SupermuxZeronFlatText: Sendable, Equatable {
    public var text: String
    public var runs: [SupermuxZeronTextRun]
    /// Byte ranges that are clickable, with their destinations. Adjacent runs
    /// sharing a URL merge into ONE range, so `[**bold** tail](url)` is one hit
    /// region and not two.
    public var links: [(range: Range<Int>, url: String)]
    /// Byte ranges wearing the violet wash. Adjacent code runs merge into ONE
    /// box; separated ones each get their own.
    public var codeRanges: [Range<Int>]

    public init(
        text: String,
        runs: [SupermuxZeronTextRun],
        links: [(range: Range<Int>, url: String)] = [],
        codeRanges: [Range<Int>] = []
    ) {
        self.text = text
        self.runs = runs
        self.links = links
        self.codeRanges = codeRanges
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
            && lhs.runs == rhs.runs
            && lhs.codeRanges == rhs.codeRanges
            && lhs.links.count == rhs.links.count
            && zip(lhs.links, rhs.links).allSatisfy { $0.range == $1.range && $0.url == $1.url }
    }

    /// Flatten parsed inline runs into paint-ready form.
    ///
    /// `baseWeight` is 400 in a paragraph, 600 in a heading (`bold_default`),
    /// and 700 in a table header. A strong run is promoted to SEMIBOLD 600 only
    /// when the base is below it, so a strong run inside a 700 table header
    /// STAYS 700 and never drops to 600 (`render.rs:548`).
    public static func flatten(
        runs: [SupermuxZeronInlineRun],
        theme: SupermuxZeronTheme,
        baseWeight: SupermuxZeronFontWeight
    ) -> SupermuxZeronFlatText {
        var text = ""
        var out: [SupermuxZeronTextRun] = []
        var links: [(range: Range<Int>, url: String)] = []
        var codeRanges: [Range<Int>] = []
        out.reserveCapacity(runs.count)

        for run in runs where !run.text.isEmpty {
            let start = text.utf8.count
            text += run.text
            let end = text.utf8.count

            let weight: SupermuxZeronFontWeight =
                run.style.bold && baseWeight.rawValue < SupermuxZeronFontWeight.semibold.rawValue
                    ? .semibold
                    : baseWeight
            // Inline code reads violet; everything else — LINKS INCLUDED —
            // stays the monochrome foreground. "Links stay monochrome —
            // foreground with an underline (zeron's md theme underlines in the
            // text color; indigo is reserved for primary actions)."
            let color = run.style.code ? theme.codeText : theme.text

            if run.style.code {
                // Merge adjacent code runs into ONE wash box.
                if let last = codeRanges.last, last.upperBound == start {
                    codeRanges[codeRanges.count - 1] = last.lowerBound..<end
                } else {
                    codeRanges.append(start..<end)
                }
            }
            if let url = run.style.link, url != SupermuxZeronMend.pendingLinkURL {
                // A still-streaming link keeps link STYLING — so the URL's
                // completion changes nothing visually — but is not clickable
                // until the real destination exists.
                if let last = links.last, last.range.upperBound == start, last.url == url {
                    links[links.count - 1] = (last.range.lowerBound..<end, url)
                } else {
                    links.append((start..<end, url))
                }
            }
            out.append(
                SupermuxZeronTextRun(
                    text: run.text,
                    isMono: run.style.code,
                    weight: weight,
                    isItalic: run.style.italic,
                    color: color,
                    link: run.style.link,
                    isStrikethrough: run.style.strikethrough
                )
            )
        }
        return SupermuxZeronFlatText(
            text: text,
            runs: out,
            links: links,
            codeRanges: codeRanges
        )
    }
}

// MARK: - Layout

/// A laid-out block: its height, its per-visual-line inline-code wash rects,
/// and the link hit regions.
public struct SupermuxZeronTextLayout: Sendable, Equatable {
    public var height: CGFloat
    /// Rounded wash quads — ONE PER VISUAL LINE that a code span covers,
    /// already inset by `padX 2` / `insetY 2`.
    public var codeRects: [CGRect]
    /// Per-link hit regions, one rect per visual line, paired with the URL.
    public var linkRects: [(rect: CGRect, url: String)]

    public init(
        height: CGFloat,
        codeRects: [CGRect] = [],
        linkRects: [(rect: CGRect, url: String)] = []
    ) {
        self.height = height
        self.codeRects = codeRects
        self.linkRects = linkRects
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.height == rhs.height
            && lhs.codeRects == rhs.codeRects
            && lhs.linkRects.count == rhs.linkRects.count
            && zip(lhs.linkRects, rhs.linkRects).allSatisfy { $0.rect == $1.rect && $0.url == $1.url }
    }
}

/// The TextKit 2 engine: builds the attributed string, pins the line box, lays
/// out, and reports segment geometry.
///
/// A stateless layout service over TextKit: every entry point is a pure
/// `(input) -> geometry` call with no stored state.
/// lint:allow namespace-enum, namespace-type — stateless layout service.
public enum SupermuxZeronTextKit {
    /// Build the `NSAttributedString` for a flat block at a fixed line box.
    ///
    /// `veilSpans` multiply alpha into the foreground color per byte range.
    /// **Only the color changes** — the font, the paragraph style and the byte
    /// lengths are identical with and without the veil, which is what makes the
    /// streaming fade layout-free.
    public static func attributedString(
        for flat: SupermuxZeronFlatText,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        theme: SupermuxZeronTheme,
        veilSpans: [SupermuxZeronVeilSpan] = []
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = paragraphStyle(lineHeight: lineHeight)

        var byteOffset = 0
        for run in flat.runs {
            let font = run.isMono
                ? SupermuxZeronFonts.platformMono(size: fontSize, weight: run.weight)
                : SupermuxZeronFonts.platformSans(size: fontSize, weight: run.weight)
            let resolved = run.isItalic ? italicized(font) : font

            // The veil's alpha for this run. A run is split by a span boundary
            // only in zeron's model; here the span alpha is sampled at the
            // run's start and any interior boundary re-splits below.
            let alpha = SupermuxZeronRowVeil.opacity(at: byteOffset, in: veilSpans)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: resolved,
                .paragraphStyle: paragraph,
                .foregroundColor: platformColor(run.color, alpha: alpha),
            ]
            if run.link != nil {
                // The underline is MUTED GREY while the glyphs stay full
                // strength `theme.text` — not the other way round.
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = platformColor(theme.textMuted, alpha: alpha)
            }
            if run.isStrikethrough {
                // Same split: the LINE is muted, the glyphs are not.
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = platformColor(theme.textMuted, alpha: alpha)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
            byteOffset += run.byteLength
        }

        // Re-apply the veil where a span boundary falls INSIDE a run. Doing it
        // as a second pass keeps the common (settled) case a single attribute
        // build, and a foreground-color-only override never touches layout.
        if !veilSpans.isEmpty {
            applyVeil(veilSpans, to: result, text: flat.text)
        }
        return result
    }

    /// The fixed line box. `minimumLineHeight == maximumLineHeight` is what
    /// makes a line box ABSOLUTE rather than a floor.
    public static func paragraphStyle(lineHeight: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        // Markdown prose is leading-aligned everywhere except table cells,
        // which override this on their own copy.
        style.alignment = .natural
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Lay out a block at `width` and report its height plus the per-visual-line
    /// rects for the inline-code washes and the link hit regions.
    ///
    /// The rects come from `enumerateTextSegments(in:type:.standard)`, which
    /// returns one rect per visual line a range covers — the same geometry
    /// `range_rects` derives by binary search over glyph positions.
    public static func layout(
        attributed: NSAttributedString,
        text: String,
        width: CGFloat,
        codeRanges: [Range<Int>],
        links: [(range: Range<Int>, url: String)],
        insetY: CGFloat = SupermuxZeronMetrics.Markdown.inlineCodeInsetY,
        padX: CGFloat = SupermuxZeronMetrics.Markdown.inlineCodePadX
    ) -> SupermuxZeronTextLayout {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(width, 1), height: 1e7))
        // gpui text has no container inset; a lineFragmentPadding of 5 would
        // shift every glyph and every wash rect right by 5 pt.
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        storage.textStorage?.setAttributedString(attributed)
        manager.ensureLayout(for: manager.documentRange)

        var height: CGFloat = 0
        manager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout, .estimatesSize]
        ) { fragment in
            height = max(height, fragment.layoutFragmentFrame.maxY)
            return true
        }

        let codeRects = codeRanges.flatMap { range in
            segmentRects(manager: manager, text: text, byteRange: range).map { rect in
                // x extends `padX` past the glyphs on EACH side; y insets
                // `insetY` from top AND bottom of the line box, so a 22 pt box
                // yields an 18 pt wash.
                CGRect(
                    x: rect.minX - padX,
                    y: rect.minY + insetY,
                    width: rect.width + 2 * padX,
                    height: rect.height - 2 * insetY
                )
            }
        }
        let linkRects = links.flatMap { link in
            segmentRects(manager: manager, text: text, byteRange: link.range)
                .map { (rect: $0, url: link.url) }
        }
        return SupermuxZeronTextLayout(
            height: height,
            codeRects: codeRects,
            linkRects: linkRects
        )
    }

    /// The per-visual-line rects covering a UTF-8 byte range — **exactly one
    /// rect per visual line**, which is what `range_rects` produces.
    ///
    /// `enumerateTextSegments` does NOT guarantee one callback per visual line.
    /// It splits a line's range at internal boundaries and, when the range ends
    /// at the document end, can report the same segment twice. Measured on this
    /// toolchain: a trailing code span yields two IDENTICAL rects, so filling
    /// them both double-paints the translucent violet wash and the span reads
    /// darker than an interior one. Coalescing per line fixes that and is also
    /// the faithful shape: a code range is contiguous, so its extent on any one
    /// visual line is a single horizontal span.
    static func segmentRects(
        manager: NSTextLayoutManager,
        text: String,
        byteRange: Range<Int>
    ) -> [CGRect] {
        guard let range = textRange(manager: manager, text: text, byteRange: byteRange) else {
            return []
        }
        var segments: [CGRect] = []
        manager.enumerateTextSegments(
            in: range,
            type: .standard,
            options: []
        ) { _, rect, _, _ in
            // A zero-width segment is a caret position, not a covered glyph.
            if rect.width > 0 { segments.append(rect) }
            return true
        }
        return coalescePerLine(segments)
    }

    /// Merge segments that sit on the same visual line into one rect spanning
    /// from the leftmost to the rightmost edge.
    ///
    /// Lines are keyed by their `minY` rounded to 1/16 pt: TextKit reports the
    /// same fragment's origin bit-identically, and the rounding only guards
    /// against a sub-ulp difference between two callbacks for one line.
    static func coalescePerLine(_ segments: [CGRect]) -> [CGRect] {
        guard segments.count > 1 else { return segments }
        var byLine: [Int: CGRect] = [:]
        var order: [Int] = []
        for segment in segments {
            let key = Int((segment.minY * 16).rounded())
            if let existing = byLine[key] {
                let minX = min(existing.minX, segment.minX)
                let maxX = max(existing.maxX, segment.maxX)
                byLine[key] = CGRect(
                    x: minX,
                    y: existing.minY,
                    width: maxX - minX,
                    height: max(existing.height, segment.height)
                )
            } else {
                byLine[key] = segment
                order.append(key)
            }
        }
        // Document order: lines come back top to bottom, as they were emitted.
        return order.compactMap { byLine[$0] }
    }

    /// Convert a UTF-8 byte range into an `NSTextRange`.
    private static func textRange(
        manager: NSTextLayoutManager,
        text: String,
        byteRange: Range<Int>
    ) -> NSTextRange? {
        guard let utf16 = utf16Range(text: text, byteRange: byteRange) else { return nil }
        let start = manager.documentRange.location
        guard let from = manager.location(start, offsetBy: utf16.location),
              let to = manager.location(from, offsetBy: utf16.length) else { return nil }
        return NSTextRange(location: from, end: to)
    }

    /// UTF-8 byte range → UTF-16 `NSRange`, the unit AppKit/UIKit speak.
    static func utf16Range(text: String, byteRange: Range<Int>) -> NSRange? {
        let utf8 = text.utf8
        guard byteRange.lowerBound >= 0, byteRange.upperBound <= utf8.count,
              byteRange.lowerBound <= byteRange.upperBound else { return nil }
        guard let lower = utf8.index(
            utf8.startIndex,
            offsetBy: byteRange.lowerBound,
            limitedBy: utf8.endIndex
        ),
            let upper = utf8.index(
                utf8.startIndex,
                offsetBy: byteRange.upperBound,
                limitedBy: utf8.endIndex
            ),
            let lowerScalar = lower.samePosition(in: text),
            let upperScalar = upper.samePosition(in: text) else { return nil }
        let location = text.utf16.distance(from: text.startIndex, to: lowerScalar)
        let length = text.utf16.distance(from: lowerScalar, to: upperScalar)
        return NSRange(location: location, length: length)
    }

    /// Multiply the veil alphas into the paint colors over their exact ranges.
    ///
    /// Foreground, underline and strikethrough colors all take the alpha, which
    /// mirrors `apply_veil`'s per-field `.opacity(alpha)`. The font is never
    /// touched, so layout is untouched.
    private static func applyVeil(
        _ spans: [SupermuxZeronVeilSpan],
        to attributed: NSMutableAttributedString,
        text: String
    ) {
        for span in spans where span.opacity < 1 {
            guard let range = utf16Range(text: text, byteRange: span.range),
                  range.length > 0,
                  NSMaxRange(range) <= attributed.length else { continue }
            for key in [
                NSAttributedString.Key.foregroundColor,
                .underlineColor,
                .strikethroughColor,
            ] {
                attributed.enumerateAttribute(key, in: range) { value, sub, _ in
                    guard let color = value as? SupermuxZeronPlatformColor else { return }
                    attributed.addAttribute(
                        key,
                        value: color.withMultipliedAlpha(span.opacity),
                        range: sub
                    )
                }
            }
        }
    }

    // MARK: Platform bridging

    /// Geist ships no italic file. `FontStyle::Italic` is set in zeron, so the
    /// platform either applies a `slnt`/`ital` axis or synthesizes an oblique
    /// (spec 05 §10.2 flags this as UNKNOWN upstream). Ask for the trait and
    /// fall back to the upright face rather than to a different family.
    private static func italicized(
        _ font: SupermuxZeronPlatformFont
    ) -> SupermuxZeronPlatformFont {
        #if canImport(AppKit)
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #elseif canImport(UIKit)
        guard let descriptor = font.fontDescriptor
            .withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        return font
        #endif
    }

    static func platformColor(_ color: Color, alpha: Double) -> SupermuxZeronPlatformColor {
        #if canImport(AppKit)
        let base = NSColor(color)
        #elseif canImport(UIKit)
        let base = UIColor(color)
        #endif
        return alpha >= 1 ? base : base.withMultipliedAlpha(alpha)
    }
}

#if canImport(AppKit)
/// The platform color type the text attributes carry.
public typealias SupermuxZeronPlatformColor = NSColor
#elseif canImport(UIKit)
/// The platform color type the text attributes carry.
public typealias SupermuxZeronPlatformColor = UIColor
#endif

extension SupermuxZeronPlatformColor {
    /// Multiply the alpha, preserving the color's own components.
    ///
    /// This is the veil's whole effect on a run — a premultiplied-alpha fade in
    /// paint only, exactly like `motion::mix`'s treatment of a transparent
    /// start: the text brightens toward its own hue and never passes through
    /// grey.
    func withMultipliedAlpha(_ factor: Double) -> SupermuxZeronPlatformColor {
        #if canImport(AppKit)
        let converted = usingColorSpace(.sRGB) ?? self
        return converted.withAlphaComponent(converted.alphaComponent * factor)
        #else
        var alpha: CGFloat = 1
        getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return withAlphaComponent(alpha * factor)
        #endif
    }
}

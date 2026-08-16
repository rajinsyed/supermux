//
//  SupermuxZeronMarkdownView.swift
//  SupermuxZeronUI
//
//  Block dispatch: paragraph, h1–h6, lists, blockquote, hr, table, code fence.
//  Spec 05 §1–§2, `render.rs:165-317`.
//
//  ── The inter-block spacing rule, in full ──
//
//  A uniform **12 pt** gap between every pair of adjacent top-level blocks,
//  regardless of type. There are no per-block-type margins, no margin
//  collapsing, no first-child/last-child cases, and no extra space around
//  headings or code blocks. It is a flex `gap`, so it never applies before the
//  first block or after the last (§0.3 C6 rules 12 over the 14 in
//  `mugen-pretext.md`; a Rust test asserts 12).
//
//  ── All block types start at the SAME x ──
//
//  Pixel-verified in `02-after.png`: the first ink of the heading, the
//  paragraph, the list marker and the code block's border all land at
//  400–401 pt. No block type is indented relative to another, and a top-level
//  list's marker column starts exactly where paragraph text does.
//
//  ── Why the recursion goes through `AnyView` ──
//
//  Markdown containers nest arbitrarily: a list item holds blocks, one of which
//  may be a blockquote, which holds blocks. A `@ViewBuilder` that calls itself
//  gives the type checker an opaque return type defined in terms of itself, and
//  a `View` struct that stores itself has infinite size. `AnyView` is the
//  standard recursion boundary for exactly this shape. It costs one existential
//  box per NESTED block — never per top-level block, and never per frame, since
//  the tree is a value the row above the lazy boundary already owns.
//

public import SwiftUI

internal import Foundation

// MARK: - The view

/// Renders a parsed markdown tree.
///
/// **List-boundary rule (cmux #2586).** This view holds NO observable store
/// reference and writes no state from `body`. Everything it needs — the parsed
/// blocks, the veil spans, the highlight documents — is passed in as a value by
/// the row above the lazy boundary. That is deliberate: a view below a
/// `LazyVStack` that reads a store reintroduces the 100 % CPU spin.
public struct SupermuxZeronMarkdownView: View {
    private typealias Md = SupermuxZeronMetrics.Markdown

    private let blocks: [SupermuxZeronBlock]
    private let theme: SupermuxZeronTheme
    /// Veil spans PER ELEMENT id. Empty for a settled row, which then renders
    /// byte-identically to a render with no veil at all.
    private let veilSpans: [Int: [SupermuxZeronVeilSpan]]
    /// Highlight documents per TOP-LEVEL block index. A missing entry renders
    /// the block plain — the faithful "highlight pending" state.
    private let highlights: [Int: [[SupermuxZeronHighlightSpan]]]
    private let onOpenURL: ((URL) -> Void)?

    public init(
        blocks: [SupermuxZeronBlock],
        theme: SupermuxZeronTheme,
        veilSpans: [Int: [SupermuxZeronVeilSpan]] = [:],
        highlights: [Int: [[SupermuxZeronHighlightSpan]]] = [:],
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.blocks = blocks
        self.theme = theme
        self.veilSpans = veilSpans
        self.highlights = highlights
        self.onOpenURL = onOpenURL
    }

    /// Parse and render in one step.
    public init(
        markdown: String,
        theme: SupermuxZeronTheme,
        isStreaming: Bool = false,
        veilSpans: [Int: [SupermuxZeronVeilSpan]] = [:],
        highlights: [Int: [[SupermuxZeronHighlightSpan]]] = [:],
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        // While streaming, the DISPLAY tree is what renders: hanging markers
        // are mended so the paragraph's tail does not reflow when a closer
        // finally arrives. A settled row parses canonically.
        self.init(
            blocks: isStreaming
                ? SupermuxZeronMarkdownParser.parseDisplay(markdown)
                : SupermuxZeronMarkdownParser.parse(markdown),
            theme: theme,
            veilSpans: veilSpans,
            highlights: highlights,
            onOpenURL: onOpenURL
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Md.blockGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                SupermuxZeronMarkdownBlockView(
                    block: block,
                    context: SupermuxZeronMarkdownContext(
                        theme: theme,
                        veilSpans: veilSpans,
                        highlights: highlights,
                        onOpenURL: onOpenURL
                    ),
                    topIndex: index,
                    elementID: index,
                    highlightable: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `heading_metrics` (`render.rs:321`). h4, h5 and h6 are IDENTICAL to a
    /// bold paragraph — the `_` arm catches all three.
    static func headingMetrics(_ level: Int) -> (size: CGFloat, lineHeight: CGFloat) {
        switch level {
        case 1: (SupermuxZeronMetrics.Markdown.h1Size, SupermuxZeronMetrics.Markdown.h1LineHeight)
        case 2: (SupermuxZeronMetrics.Markdown.h2Size, SupermuxZeronMetrics.Markdown.h2LineHeight)
        case 3: (SupermuxZeronMetrics.Markdown.h3Size, SupermuxZeronMetrics.Markdown.h3LineHeight)
        default: (SupermuxZeronMetrics.Markdown.h4Size, SupermuxZeronMetrics.Markdown.h4LineHeight)
        }
    }
}

// MARK: - Context

/// The values every block in one tree shares. Bundled so the recursion carries
/// one parameter instead of four.
struct SupermuxZeronMarkdownContext {
    let theme: SupermuxZeronTheme
    let veilSpans: [Int: [SupermuxZeronVeilSpan]]
    let highlights: [Int: [[SupermuxZeronHighlightSpan]]]
    let onOpenURL: ((URL) -> Void)?

    func spans(_ elementID: Int) -> [SupermuxZeronVeilSpan] {
        veilSpans[elementID] ?? []
    }
}

// MARK: - One block

/// One markdown block, at any nesting depth.
struct SupermuxZeronMarkdownBlockView: View {
    private typealias Md = SupermuxZeronMetrics.Markdown

    let block: SupermuxZeronBlock
    let context: SupermuxZeronMarkdownContext
    /// The enclosing TOP-LEVEL block index — the highlight lookup's scope.
    let topIndex: Int
    /// The per-element discriminator that keys the veil.
    let elementID: Int
    /// False inside a blockquote or a list item: a fence nested there is NEVER
    /// highlighted, because zeron passes `None` for `highlight` at both nesting
    /// sites (`render.rs:245`, `299`).
    let highlightable: Bool

    var body: some View {
        switch block {
        case .paragraph(let runs):
            text(runs, size: Md.textSize, lineHeight: Md.lineHeight)

        case .heading(let level, let runs):
            let metrics = SupermuxZeronMarkdownView.headingMetrics(level)
            // `boldDefault = true` ⇒ SEMIBOLD 600 as the BASE weight for the
            // whole heading. No colour change, no letter-spacing, no uppercase,
            // no underline, no rule — headings are pure size + weight.
            text(
                runs,
                size: metrics.size,
                lineHeight: metrics.lineHeight,
                baseWeight: .semibold
            )

        case .codeBlock(let language, let code):
            SupermuxZeronCodeBlock(
                language: language,
                code: code,
                theme: context.theme,
                veilSpans: context.spans(elementID),
                highlight: highlightable ? context.highlights[topIndex] : nil
            )

        case .blockQuote(let children):
            blockquote(children)

        case .list(let orderedStart, let items):
            list(orderedStart: orderedStart, items: items)

        case .table(let header, let rows, let align):
            SupermuxZeronMarkdownTable(
                header: header,
                rows: rows,
                align: align,
                theme: context.theme,
                elementID: elementID,
                veilSpans: context.veilSpans,
                onOpenURL: context.onOpenURL
            )

        case .rule:
            // A 1 pt hairline with 12 pt of air on each side — the block gap
            // and nothing else.
            Rectangle()
                .fill(context.theme.border)
                .frame(height: Md.ruleHeight)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Text

    private func text(
        _ runs: [SupermuxZeronInlineRun],
        size: CGFloat,
        lineHeight: CGFloat,
        baseWeight: SupermuxZeronFontWeight = .regular
    ) -> some View {
        SupermuxZeronMarkdownText(
            flat: SupermuxZeronFlatText.flatten(
                runs: runs,
                theme: context.theme,
                baseWeight: baseWeight
            ),
            fontSize: size,
            lineHeight: lineHeight,
            theme: context.theme,
            veilSpans: context.spans(elementID),
            onOpenURL: context.onOpenURL
        )
    }

    // MARK: Blockquote

    private func blockquote(_ children: [SupermuxZeronBlock]) -> some View {
        // NOTE on the muted text colour: zeron sets `text_color(text_muted)` on
        // the quote container, but `flatten_runs_weighted` assigns
        // `color: theme.text` to every non-code run EXPLICITLY, so the
        // container colour never reaches prose. Quoted prose paints
        // `theme.text`, not muted — reproduced by simply not overriding it.
        VStack(alignment: .leading, spacing: Md.quoteInnerGap) {
            ForEach(Array(children.enumerated()), id: \.offset) { childIndex, child in
                nested(child, elementID: elementID * 100 + childIndex)
            }
        }
        .padding(.leading, Md.quotePadLeading)
        // Asymmetric on purpose: pl 12 / pr 10 is not a typo.
        .padding(.trailing, Md.quotePadTrailing)
        .padding(.vertical, Md.quotePadY)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Only the TRAILING corners are rounded; the rail edge is square.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: Md.quoteTrailingRadius,
                topTrailingRadius: Md.quoteTrailingRadius,
                style: .continuous
            )
            .fill(context.theme.accent.opacity(Md.quoteFillAlpha))
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(context.theme.accent.opacity(Md.quoteRailAlpha))
                .frame(width: Md.quoteRailWidth)
        }
    }

    // MARK: Lists

    private func list(orderedStart: UInt64?, items: [[SupermuxZeronBlock]]) -> some View {
        // A top-level list gets NO extra indent: its marker column starts at
        // the same x as paragraph text.
        VStack(alignment: .leading, spacing: Md.listItemGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                HStack(alignment: .top, spacing: Md.listMarkerGap) {
                    marker(orderedStart: orderedStart, itemIndex: itemIndex)
                    VStack(alignment: .leading, spacing: Md.listItemGap) {
                        ForEach(Array(item.enumerated()), id: \.offset) { childIndex, child in
                            nested(
                                child,
                                elementID: elementID * 100 + itemIndex * 10 + childIndex
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(orderedStart: UInt64?, itemIndex: Int) -> some View {
        // "Accent markers (the inline-code hue): ordered numbers as tinted
        // text, unordered as a REAL 5px disc — the glyph '•' reads too small
        // at 14px."
        if let start = orderedStart {
            // The AUTHORED start number is honoured: `5. 6. 7.` renders 5, 6, 7.
            Text(verbatim: "\(start &+ UInt64(itemIndex)).")
                .font(SupermuxZeronFonts.sans(size: Md.textSize))
                .foregroundStyle(context.theme.accent.opacity(Md.listMarkerAlpha))
                // Leading-aligned in its 18 pt column, NOT right-aligned. The
                // column GROWS for a wider numeral (`10.`, `100.`).
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: Md.listMarkerMinWidth, alignment: .leading)
                .frame(height: Md.lineHeight, alignment: .leading)
        } else {
            // A REAL drawn disc, never the `•` glyph.
            Circle()
                .fill(context.theme.accent.opacity(Md.listMarkerAlpha))
                .frame(width: Md.listDiscDiameter, height: Md.listDiscDiameter)
                .padding(.leading, Md.listDiscLeftMargin)
                // Centred in a 22 pt box — i.e. on the first text line's cap
                // band, which puts the disc top 8.5 pt below the item top.
                .frame(width: Md.listMarkerMinWidth, height: Md.lineHeight, alignment: .leading)
        }
    }

    /// The recursion boundary. See the file header for why it is `AnyView`.
    ///
    /// Nested children are never highlighted, which is why `highlightable` is
    /// hard-coded false here rather than threaded.
    private func nested(_ child: SupermuxZeronBlock, elementID: Int) -> AnyView {
        AnyView(
            SupermuxZeronMarkdownBlockView(
                block: child,
                context: context,
                topIndex: topIndex,
                elementID: elementID,
                highlightable: false
            )
        )
    }
}

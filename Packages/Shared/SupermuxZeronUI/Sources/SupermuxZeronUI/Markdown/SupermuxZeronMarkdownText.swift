//
//  SupermuxZeronMarkdownText.swift
//  SupermuxZeronUI
//
//  The SwiftUI seat for one text block: a TextKit 2 layout, the rounded
//  inline-code wash painted UNDER the glyphs, and the link hit regions.
//
//  ── Why the wash is a Canvas and not a background attribute ──
//
//  `NSAttributedString.backgroundColor` paints a square box with no radius and
//  no horizontal overhang — the exact limitation `render.rs:492-494` calls out
//  and the reason zeron paints its own quads from a canvas UNDERLAY sibling.
//  The rects come from `enumerateTextSegments(in:type:.standard)`, which
//  returns ONE RECT PER VISUAL LINE, so a code span that soft-wraps gets two
//  separate rounded boxes each with its own 2 pt overhang — not one continuous
//  shape.
//
//  ── The layout is computed, not measured by SwiftUI ──
//
//  The block reports its own height from the same `NSTextLayoutManager` that
//  produced the wash rects, so the geometry the wash is drawn against and the
//  geometry the row is sized to are the SAME layout. Sizing the text with
//  SwiftUI and the wash with TextKit would drift by a fraction and the boxes
//  would sit off the glyphs.
//

internal import SwiftUI

internal import CoreGraphics
internal import Foundation

/// One markdown text block, rendered through TextKit 2.
struct SupermuxZeronMarkdownText: View {
    private typealias Md = SupermuxZeronMetrics.Markdown

    let flat: SupermuxZeronFlatText
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let theme: SupermuxZeronTheme
    let veilSpans: [SupermuxZeronVeilSpan]
    let onOpenURL: ((URL) -> Void)?

    /// The attributed string, built ONCE per constructed block.
    ///
    /// It used to be a computed property that one `body` pass read three times —
    /// `measuredHeight` → `cachedLayout`, `content(width:)` → `cachedLayout`, and
    /// `textView(width:)` — so every pass built three identical
    /// `NSAttributedString`s, each one allocating a font and a paragraph style
    /// per run. A streaming paragraph re-renders at the veil's 30 fps, so that
    /// was three full attribute builds per block per frame. Same hoist, and the
    /// same reason, as ``SupermuxZeronAssistantRow``'s parse.
    private let attributed: NSAttributedString

    init(
        flat: SupermuxZeronFlatText,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        theme: SupermuxZeronTheme,
        veilSpans: [SupermuxZeronVeilSpan],
        onOpenURL: ((URL) -> Void)?
    ) {
        self.flat = flat
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.theme = theme
        self.veilSpans = veilSpans
        self.onOpenURL = onOpenURL
        self.attributed = SupermuxZeronTextKit.attributedString(
            for: flat,
            fontSize: fontSize,
            lineHeight: lineHeight,
            theme: theme,
            veilSpans: veilSpans
        )
    }

    var body: some View {
        // The width is the only layout input; the height falls out of it.
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .frame(height: measuredHeight)
    }

    /// The layout at a placeholder width, used only to reserve height before
    /// the geometry reader reports the real one. Both use the SAME engine.
    private var measuredHeight: CGFloat {
        // A single-line block is the common case and its height is exactly the
        // line box, independent of width; only a wrapping block needs the real
        // width, and the geometry reader supplies it on the next pass.
        max(lineHeight, cachedLayout(width: lastKnownWidth).height)
    }

    @State private var lastKnownWidth: CGFloat = SupermuxZeronMetrics.Transcript.maxContentWidth

    private func content(width: CGFloat) -> some View {
        let layout = cachedLayout(width: width)
        return ZStack(alignment: .topLeading) {
            // The wash is painted FIRST — an earlier sibling is underneath.
            Canvas { context, _ in
                for rect in layout.codeRects {
                    context.fill(
                        Path(
                            roundedRect: rect,
                            cornerRadius: Md.inlineCodeRadius,
                            style: .continuous
                        ),
                        with: .color(theme.codeWash)
                    )
                }
            }
            .allowsHitTesting(false)

            textView(width: width)

            // Link hit regions, one per visual line a link covers, so a link
            // that wraps stays clickable on both rows.
            ForEach(Array(layout.linkRects.enumerated()), id: \.offset) { _, hit in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: hit.rect.width, height: hit.rect.height)
                    .offset(x: hit.rect.minX, y: hit.rect.minY)
                    .onTapGesture { open(hit.url) }
                    #if os(macOS)
                    // A link has NO hover state — no colour change, no
                    // underline change. Only the cursor changes.
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    #endif
            }
        }
        .frame(width: width, height: layout.height, alignment: .topLeading)
        .onAppear { lastKnownWidth = width }
        .onChange(of: width) { _, new in lastKnownWidth = new }
    }

    private func textView(width: CGFloat) -> some View {
        SupermuxZeronTextKitTextView(
            attributed: attributed,
            width: width,
            selectable: true
        )
    }

    private func cachedLayout(width: CGFloat) -> SupermuxZeronTextLayout {
        SupermuxZeronTextKit.layout(
            attributed: attributed,
            text: flat.text,
            width: width,
            codeRanges: flat.codeRanges,
            links: flat.links
        )
    }

    private func open(_ url: String) {
        guard let parsed = URL(string: url) else { return }
        if let onOpenURL {
            onOpenURL(parsed)
            return
        }
        #if canImport(AppKit)
        NSWorkspace.shared.open(parsed)
        #elseif canImport(UIKit)
        UIApplication.shared.open(parsed)
        #endif
    }
}

// MARK: - The platform text view

#if canImport(AppKit)
internal import AppKit

/// An `NSTextView` in TextKit 2 mode, sized by its own layout.
///
/// Selection is PER BLOCK — the accepted v1 deviation (plan R8). zeron
/// rebuilds cross-block selection with a document-ordered registry plus
/// window-level mouse listeners; a drag here cannot span a heading and the
/// paragraph under it, and ⌘C over a multi-block answer copies one block.
struct SupermuxZeronTextKitTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let width: CGFloat
    let selectable: Bool

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(
            frame: .zero,
            textContainer: NSTextContainer(size: CGSize(width: width, height: 1e7))
        )
        configure(view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        configure(view)
        view.textContainer?.size = CGSize(width: max(width, 1), height: 1e7)
        if view.textStorage?.isEqual(to: attributed) != true {
            view.textStorage?.setAttributedString(attributed)
        }
    }

    private func configure(_ view: NSTextView) {
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = selectable
        view.isRichText = false
        view.importsGraphics = false
        // gpui text has no container inset. A default 5 pt lineFragmentPadding
        // and a (5, 0) textContainerInset would shift every glyph — and every
        // wash rect the Canvas draws from the SAME geometry — to the right.
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [:]
    }
}
#elseif canImport(UIKit)
internal import UIKit

/// A `UITextView` in TextKit 2 mode, sized by its own layout. Same per-block
/// selection deviation as the AppKit seat above.
struct SupermuxZeronTextKitTextView: UIViewRepresentable {
    let attributed: NSAttributedString
    let width: CGFloat
    let selectable: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        configure(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        configure(view)
        if view.attributedText != attributed {
            view.attributedText = attributed
        }
    }

    private func configure(_ view: UITextView) {
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = selectable
        view.isScrollEnabled = false
        // Same zero-inset rule as AppKit: the Canvas draws the wash from this
        // container's geometry, so any inset here desynchronizes the two.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.linkTextAttributes = [:]
    }
}
#endif

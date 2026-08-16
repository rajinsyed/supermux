//
//  SupermuxZeronAssistantRow.swift
//  SupermuxZeronUI
//
//  The markdown block row.
//
//  ── Its whole identity is what it does NOT have ──
//
//  **No plate, no indent, flush to the column's left edge.** The user's message
//  gets a bubble; the assistant's reply does not. Pixel-verified in
//  `02-after.png`: the heading, the paragraph, the list markers and the code
//  block's border all start at the SAME x as one another and as the column
//  itself. Any background, any leading padding, any avatar gutter here is a
//  visible deviation.
//
//  ── Streaming ──
//
//  The row owns its `SupermuxZeronRowVeil` and advances it once per frame while
//  the block streams. The veil is created SEEDED when the row already carried
//  text at mount, so re-attaching to a live session does not dissolve the whole
//  existing reply.
//
//  ── List-boundary rule (cmux #2586) ──
//
//  This view sits BELOW the transcript's lazy boundary, so it holds no
//  observable store reference, and nothing called from `body` writes state. The
//  veil advances from the SHARED 30 fps pulse clock's published frame counter —
//  a value the view reads, not a mutation it performs during layout — and the
//  parse is a pure function of the text.
//
//  ── Why the pulse clock and NOT `TimelineView(.animation)` ──
//
//  `TimelineView(.animation)` drives at the display's NATIVE refresh rate and
//  keeps CoreAnimation's render server awake for as long as it is mounted —
//  120 Hz on a ProMotion display, for every streaming row at once. That is the
//  exact primitive plan R12 forbids (zeron measured 36 % CPU at 120 Hz for a
//  single 10×10 pt spinner, which is why the shared clock exists at all), and a
//  virtualized transcript can have several live rows mounted simultaneously.
//
//  The veil's own numbers make 30 fps the right rate independently: a chunk
//  fades over 120–400 ms, so 30 fps gives it 4–12 frames, and zeron's own frame
//  discipline is "one repaint per frame while any chunk is fading, none once
//  settled". The lease delivers the second half of that for free — the row
//  stops renewing the moment nothing fades, and the clock parks within 300 ms.
//

public import SwiftUI

internal import Foundation

/// One assistant markdown block, flush in the content column.
public struct SupermuxZeronAssistantRow: View {
    private let text: String
    private let isStreaming: Bool
    private let theme: SupermuxZeronTheme
    /// Stable across appends — it keys the veil's per-element state.
    private let rowKey: String
    private let onOpenURL: ((URL) -> Void)?

    @State private var model: SupermuxZeronStreamingMarkdownModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One cache per transcript, injected at the shell. Reading it from the
    /// environment keeps this row free of a global (see `SupermuxZeronSyntax`).
    @Environment(\.supermuxZeronSyntaxCache) private var syntaxCache
    /// The shared 30 fps clock that drives the streaming fade. Overridable so a
    /// test or preview can step it by hand.
    @Environment(\.supermuxZeronPulseClock) private var clockOverride

    public init(
        text: String,
        isStreaming: Bool,
        theme: SupermuxZeronTheme,
        rowKey: String,
        /// True when the row already carried text at mount — the veil then
        /// SEEDS instead of fading (a re-attach, not a fresh stream).
        seeded: Bool = false,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.theme = theme
        self.rowKey = rowKey
        self.onOpenURL = onOpenURL
        _model = State(initialValue: SupermuxZeronStreamingMarkdownModel(seeded: seeded))
    }

    public var body: some View {
        Group {
            // With Reduce Motion on there is NO fade at all — the text appears
            // at full opacity. zeron builds no veil in that case
            // (`transcript.rs:2817`), rather than building one and snapping it.
            if isStreaming, !reduceMotion {
                markdown(veilSpans: streamingSpans)
            } else {
                markdown(veilSpans: [:])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: highlightKey) { await loadHighlights() }
    }

    /// The current veil spans, advanced on the shared 30 fps clock.
    ///
    /// Reading `frame` is what subscribes this row to the clock, and the lease
    /// renewal is the clock's own bookkeeping — neither is a write to view
    /// state, so the list-boundary rule holds. The lease is renewed only while
    /// something is actually fading, so a settled row lets the clock park.
    private var streamingSpans: [Int: [SupermuxZeronVeilSpan]] {
        let clock = clockOverride ?? SupermuxZeronPulseClock.shared
        // Subscribe to the tick. The value is unused: the clock's own epoch is
        // not the veil's time base — chunk ages are wall-clock — but observing
        // `frame` is what re-renders this row each tick.
        _ = clock.frame
        let spans = model.spans(for: text, at: Date().timeIntervalSinceReferenceDate)
        if model.isFading {
            clock.renewLease(veilLeaseID)
        } else {
            clock.releaseLease(veilLeaseID)
        }
        return spans
    }

    /// A per-row lease identity, so two streaming rows do not share one lease.
    private var veilLeaseID: String { "zeron-veil-\(rowKey)" }

    private func markdown(veilSpans: [Int: [SupermuxZeronVeilSpan]]) -> some View {
        SupermuxZeronMarkdownView(
            blocks: blocks,
            theme: theme,
            veilSpans: veilSpans,
            highlights: model.highlights,
            onOpenURL: onOpenURL
        )
    }

    /// The DISPLAY tree while streaming (hanging markers mended), the canonical
    /// tree once settled.
    private var blocks: [SupermuxZeronBlock] {
        isStreaming
            ? SupermuxZeronMarkdownParser.parseDisplay(text)
            : SupermuxZeronMarkdownParser.parse(text)
    }

    /// Re-highlight when the set of fenced blocks changes, not on every delta:
    /// recolouring cannot change layout, so it is free to lag.
    private var highlightKey: String {
        blocks.enumerated().compactMap { index, block in
            guard case .codeBlock(let language, let code) = block else { return nil }
            return "\(index)|\(language ?? "")|\(code.utf8.count)"
        }
        .joined(separator: "~")
    }

    /// Render plain first, recolour asynchronously. That behaviour is FAITHFUL
    /// (spec 05 §2.5.6: `CodeHighlight = None` while pending), not a defect.
    private func loadHighlights() async {
        var next: [Int: [[SupermuxZeronHighlightSpan]]] = [:]
        for (index, block) in blocks.enumerated() {
            guard case .codeBlock(let language, let code) = block,
                  let language,
                  let resolved = SupermuxZeronSyntaxLanguage.named(language) else { continue }
            next[index] = await syntaxCache.document(source: code, language: resolved)
        }
        model.highlights = next
    }
}

// MARK: - Streaming state

/// The per-row streaming state: the veil and the highlight documents.
///
/// `@Observable` and owned by the row itself, above nothing — it is the row's
/// own value, not a shared store. Advancing the veil from `spans(for:at:)`
/// mutates this object, which is why the call is made from a `TimelineView`'s
/// closure (a value read per frame) and never from `body` directly.
@Observable
@MainActor
final class SupermuxZeronStreamingMarkdownModel {
    private var veil: SupermuxZeronRowVeil
    private var didSeed: Bool
    var highlights: [Int: [[SupermuxZeronHighlightSpan]]] = [:]

    /// Any element still fading, as of the last ``spans(for:at:)``. Drives the
    /// pulse-clock lease: the row renews only while something is animating.
    var isFading: Bool { veil.isFading }

    init(seeded: Bool) {
        veil = seeded ? .seeded() : SupermuxZeronRowVeil()
        didSeed = !seeded
    }

    /// Advance every element's veil and return the current spans per element.
    ///
    /// The veil is tracked on the WHOLE text per top-level element, which is
    /// what lets a code block slice its own per-line windows out of one span
    /// set (`render.rs:1052`).
    func spans(for text: String, at now: TimeInterval) -> [Int: [SupermuxZeronVeilSpan]] {
        let blocks = SupermuxZeronMarkdownParser.parseDisplay(text)
        var out: [Int: [SupermuxZeronVeilSpan]] = [:]
        for (index, block) in blocks.enumerated() {
            let flat = Self.flatText(of: block)
            let spans = veil.advance(element: index, text: flat, now: now)
            if !spans.isEmpty { out[index] = spans }
        }
        if !didSeed {
            // The attach pass is over: elements first seen from here on are
            // newly streamed content and fade normally.
            veil.finishSeeding()
            didSeed = true
        }
        return out
    }

    /// The flat text the veil tracks for a block — the same string the renderer
    /// lays out, so a chunk's byte range lands on the right glyphs.
    private static func flatText(of block: SupermuxZeronBlock) -> String {
        switch block {
        case .paragraph(let runs), .heading(_, let runs):
            return runs.map(\.text).joined()
        case .codeBlock(_, let code):
            return code
        case .blockQuote(let children):
            return children.map(flatText(of:)).joined()
        case .list(_, let items):
            return items.flatMap { $0 }.map(flatText(of:)).joined()
        case .table(let header, let rows, _):
            return (header + rows.flatMap { $0 })
                .flatMap { $0 }
                .map(\.text)
                .joined()
        case .rule:
            return ""
        }
    }
}

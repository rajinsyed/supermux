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
//  observable store reference, and **nothing called from `body` writes state**.
//
//  That second half is not a style rule, it is the difference between a working
//  app and a force quit. The veil is time-driven MUTABLE state: advancing it
//  registers chunks, prunes settled ones and updates the cadence EMA. An earlier
//  revision of this file advanced it from a computed property that `body` read.
//  SwiftUI then saw the body it was evaluating write the observable state that
//  same body depends on, invalidated the view, re-evaluated it, wrote again —
//  an unbounded render loop with the main thread pinned at 100 % and the whole
//  app frozen (sampled live: `body.getter` → `streamingSpans.getter` →
//  `veil.modify`, over and over, inside one `GraphHost.flushTransactions`).
//
//  The split that makes it safe:
//
//  * **`body` PROJECTS.** It asks the veil what its spans WOULD be for this text
//    at this instant (``SupermuxZeronRowVeil/projected(element:text:now:)``),
//    which runs the same math on a local copy and commits nothing. Reading the
//    committed veil is what subscribes the row, so a later advance repaints it.
//  * **A `.task` COMMITS.** The driver below advances the real veil once per
//    30 fps pulse-clock frame, from outside the render pass, and stops the
//    moment nothing fades.
//
//  Projecting rather than rendering the last committed spans is what keeps the
//  fade seamless: `.task` runs after the update that carried the new text, so a
//  row that painted committed-only spans would flash one frame of full-opacity
//  text before the fade started, on every delta.
//
//  The parse is hoisted into `init` for the same family of reasons — see
//  ``blocks``.
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
//  The row takes the clock's tick through ``SupermuxZeronPulseClock/nextFrame``
//  (an `await`) rather than through its `frame` counter (an observable read),
//  because the advance is a mutation and must not happen during render. A local
//  `TimelineView(.periodic)` would also move the advance out of `body`, but the
//  pulse clock's header rejects per-view timers outright: they reintroduce
//  per-view clocks and lose the shared-epoch phase lock, and N streaming rows
//  would mean N timers instead of one.
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

    /// The parsed tree and its highlight key, computed ONCE per constructed row.
    ///
    /// `blocks` used to be a computed property, which meant a full markdown
    /// re-parse on every access: once for the render, once for `highlightKey`,
    /// and a third and fourth time inside the veil advance — four parses of the
    /// WHOLE reply per render pass, on text that grows without bound while it
    /// streams. Parsing in `init` makes it once per `(text, isStreaming)`, since
    /// SwiftUI only reconstructs the row when one of those changed.
    private let parsed: Parsed

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
        self.parsed = Parsed(text: text, isStreaming: isStreaming)
        _model = State(initialValue: SupermuxZeronStreamingMarkdownModel(seeded: seeded))
    }

    public var body: some View {
        Group {
            // With Reduce Motion on there is NO fade at all — the text appears
            // at full opacity. zeron builds no veil in that case
            // (`transcript.rs:2817`), rather than building one and snapping it.
            if isStreaming, !reduceMotion {
                markdown(veilSpans: projectedSpans)
            } else {
                markdown(veilSpans: [:])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: highlightKey) { await loadHighlights() }
        .task(id: veilDriverKey) { await driveVeil() }
    }

    /// The spans to PAINT this pass — a pure projection, committing nothing.
    ///
    /// Reads the model (which subscribes the row to every committed advance) and
    /// asks it what the spans would be at this instant. It writes nothing, so
    /// evaluating `body` cannot invalidate `body`.
    private var projectedSpans: [Int: [SupermuxZeronVeilSpan]] {
        model.projectedSpans(for: parsed.blocks, at: Date().timeIntervalSinceReferenceDate)
    }

    /// Restarts the driver when the row's content changes, so a delta arriving
    /// after the veil settled starts it fading again.
    ///
    /// Comparing the text is what makes a same-length rewrite (the incremental
    /// parser resolving `**bold`) restart the driver too. It is not a per-frame
    /// cost: within one row instance `text` is the same `String` storage, so the
    /// comparison SwiftUI runs every body evaluation hits the pointer-identity
    /// fast path and only walks bytes when the text genuinely changed.
    private struct VeilDriverKey: Equatable {
        let isStreaming: Bool
        let reduceMotion: Bool
        let text: String
    }

    private var veilDriverKey: VeilDriverKey {
        VeilDriverKey(isStreaming: isStreaming, reduceMotion: reduceMotion, text: text)
    }

    /// Advance the veil once per 30 fps pulse-clock frame, OUTSIDE the render
    /// pass, and stop as soon as nothing is fading.
    ///
    /// `.task` bodies run after the update that started them, never during it,
    /// which is precisely what makes the mutation safe. The loop exits when the
    /// veil settles; the next delta changes ``veilDriverKey`` and restarts it,
    /// so a settled row costs nothing at all — no timer, no lease, no repaint.
    private func driveVeil() async {
        guard isStreaming, !reduceMotion else { return }
        let clock = clockOverride ?? SupermuxZeronPulseClock.shared
        // Commit the arriving delta immediately: this is the advance that
        // REGISTERS the new chunk, and it must happen on the frame the text
        // landed rather than 33 ms later.
        model.commitSpans(for: parsed.blocks, at: Date().timeIntervalSinceReferenceDate)
        while !Task.isCancelled, model.isFading {
            await clock.nextFrame(leasedBy: veilLeaseID)
            guard !Task.isCancelled else { return }
            model.commitSpans(for: parsed.blocks, at: Date().timeIntervalSinceReferenceDate)
        }
        // Settled: drop the lease so the clock parks NOW rather than in 300 ms.
        // A CANCELLED driver deliberately does not release — the next delta's
        // driver is already starting and would only have to re-acquire it, and
        // a row that really went away has its lease expire on the 300 ms grace
        // that is the clock's documented mechanism.
        if !Task.isCancelled { clock.releaseLease(veilLeaseID) }
    }

    /// A per-row lease identity, so two streaming rows do not share one lease.
    private var veilLeaseID: String { "zeron-veil-\(rowKey)" }

    private func markdown(veilSpans: [Int: [SupermuxZeronVeilSpan]]) -> some View {
        SupermuxZeronMarkdownView(
            blocks: parsed.blocks,
            theme: theme,
            veilSpans: veilSpans,
            highlights: model.highlights,
            onOpenURL: onOpenURL
        )
    }

    /// Re-highlight when the set of fenced blocks changes, not on every delta:
    /// recolouring cannot change layout, so it is free to lag.
    private var highlightKey: String { parsed.highlightKey }

    /// Render plain first, recolour asynchronously. That behaviour is FAITHFUL
    /// (spec 05 §2.5.6: `CodeHighlight = None` while pending), not a defect.
    private func loadHighlights() async {
        var next: [Int: [[SupermuxZeronHighlightSpan]]] = [:]
        for (index, block) in parsed.blocks.enumerated() {
            guard case .codeBlock(let language, let code) = block,
                  let language,
                  let resolved = SupermuxZeronSyntaxLanguage.named(language) else { continue }
            next[index] = await syntaxCache.document(source: code, language: resolved)
        }
        model.highlights = next
    }

    // MARK: - The parse, done once

    /// The markdown tree and everything derived from it, computed in `init`.
    ///
    /// One parse per constructed row, versus the four per render pass the
    /// computed-property version cost. `highlightKey` walks the tree here too,
    /// for the same reason.
    fileprivate struct Parsed {
        let blocks: [SupermuxZeronBlock]
        let highlightKey: String

        init(text: String, isStreaming: Bool) {
            // The DISPLAY tree while streaming (hanging markers mended), the
            // canonical tree once settled.
            blocks = isStreaming
                ? SupermuxZeronMarkdownParser.parseDisplay(text)
                : SupermuxZeronMarkdownParser.parse(text)
            highlightKey = blocks.enumerated().compactMap { index, block in
                guard case .codeBlock(let language, let code) = block else { return nil }
                return "\(index)|\(language ?? "")|\(code.utf8.count)"
            }
            .joined(separator: "~")
        }
    }
}

// MARK: - Streaming state

/// The per-row streaming state: the veil and the highlight documents.
///
/// `@Observable` and owned by the row itself, above nothing — it is the row's
/// own value, not a shared store.
///
/// ── Why the API is split in two ──
///
/// Advancing the veil MUTATES this object. `body` therefore may only ever call
/// ``projectedSpans(for:at:)``, which computes the same answer without
/// committing; only the row's `.task` driver calls ``commitSpans(for:at:)``,
/// from outside the render pass. Calling the committing half from `body` makes
/// SwiftUI invalidate the view it is evaluating and re-render forever
/// (cmux #2586) — that is exactly the bug this shape exists to prevent, and it
/// froze the app hard enough to need a force quit.
@Observable
@MainActor
final class SupermuxZeronStreamingMarkdownModel {
    private var veil: SupermuxZeronRowVeil
    private var didSeed: Bool
    var highlights: [Int: [[SupermuxZeronHighlightSpan]]] = [:]

    /// Any element still fading, as of the last ``commitSpans(for:at:)``. Drives
    /// the pulse-clock lease: the row drives frames only while something is
    /// animating.
    var isFading: Bool { veil.isFading }

    init(seeded: Bool) {
        veil = seeded ? .seeded() : SupermuxZeronRowVeil()
        didSeed = !seeded
    }

    /// The spans as of `now`, committing NOTHING. Safe to call from `body`.
    ///
    /// Reading `veil` is what registers this row's observable dependency, so
    /// every committed advance repaints it.
    ///
    /// The veil is tracked on the WHOLE text per top-level element, which is
    /// what lets a code block slice its own per-line windows out of one span
    /// set (`render.rs:1052`).
    func projectedSpans(
        for blocks: [SupermuxZeronBlock],
        at now: TimeInterval
    ) -> [Int: [SupermuxZeronVeilSpan]] {
        var out: [Int: [SupermuxZeronVeilSpan]] = [:]
        for (index, block) in blocks.enumerated() {
            let spans = veil.projected(element: index, text: Self.flatText(of: block), now: now)
            if !spans.isEmpty { out[index] = spans }
        }
        return out
    }

    /// Advance every element's veil. **Never call this from `body`.**
    @discardableResult
    func commitSpans(
        for blocks: [SupermuxZeronBlock],
        at now: TimeInterval
    ) -> [Int: [SupermuxZeronVeilSpan]] {
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

//
//  SupermuxZeronVeil.swift
//  SupermuxZeronUI
//
//  The per-chunk streaming fade. A port of
//  `/tmp/zeron-comet/crates/ui/src/markdown/veil.rs` (spec 05 §4).
//
//  ── The problem it solves ──
//
//  Streamed text must commit to LAYOUT INSTANTLY, so heights are exact and the
//  stick-to-bottom spring tracks correctly — but characters appearing at full
//  opacity look like a typewriter stutter. The veil dissolves a purely cosmetic
//  opacity over the newly arrived characters: same text, same fonts, same byte
//  lengths, ZERO TRANSLATE.
//
//  ── Why it cannot change layout ──
//
//  A veil span only multiplies alpha into a run's paint color. The total run
//  length is preserved exactly, so shaping and wrapping cannot change. In the
//  TextKit path this is a `setAttributes(.foregroundColor:)` over a range with
//  the font untouched, which does not invalidate layout.
//
//  ── Frame discipline ──
//
//  While any chunk fades the host requests exactly ONE repaint next frame; once
//  settled it requests none, and ``ElemVeil/advance(text:now:)`` returns no
//  spans at all — a settled frame is byte-identical to a render with no veil.
//

public import Foundation

// MARK: - Span

/// A veiled character range and its current text opacity (0…1).
public struct SupermuxZeronVeilSpan: Sendable, Equatable {
    /// Offsets into the element's flat text, in UTF-8 BYTES — the same unit
    /// `veil.rs` uses, and the unit the TextKit renderer converts from when it
    /// resolves an `NSRange`.
    public var range: Range<Int>
    /// `1 − (1 − p)^1.6` at the current instant.
    public var opacity: Double

    public init(range: Range<Int>, opacity: Double) {
        self.range = range
        self.opacity = opacity
    }
}

// MARK: - Element veil

/// Per-element chunk tracker: remembers the last rendered flat text and fades
/// every newly appended suffix EXACTLY ONCE.
///
/// A chunk fades once and only once — already-faded text never re-animates on a
/// later append, and a fully settled element returns no spans.
public struct SupermuxZeronElemVeil: Sendable {
    /// One appended chunk mid-fade.
    private struct Chunk: Sendable {
        var range: Range<Int>
        let started: TimeInterval
        /// Fixed at ARRIVAL from the then-current cadence EMA. Later cadence
        /// changes never retime an in-flight chunk.
        let durationMS: Double
    }

    private typealias Veil = SupermuxZeronMetrics.Veil

    /// The last rendered flat text, as UTF-8 bytes — the comparison unit that
    /// makes `commonPrefix` byte-exact against the Rust.
    private var prev: [UInt8] = []
    private var chunks: [Chunk] = []
    /// EMA of inter-append gaps, in ms. Drives per-chunk durations.
    private var emaMS: Double = Veil.emaSeedMS
    private var lastAppend: TimeInterval?

    public init() {}

    /// Adopt `text` as the committed baseline WITHOUT fading it.
    ///
    /// The attach semantics of mugen's `FadePainter.attach`: content already on
    /// screen when the painter attaches never animates; only later appends do.
    public mutating func seed(_ text: String) {
        prev = Array(text.utf8)
    }

    /// Advance to `text` at `now` (seconds on any monotonic clock).
    ///
    /// Registers a fading chunk for newly appended bytes, prunes settled
    /// chunks, and returns the active spans. Idempotent for unchanged text, so
    /// it is safe to call once per frame — or twice, when a row is both
    /// measured and painted.
    public mutating func advance(text: String, now: TimeInterval) -> [SupermuxZeronVeilSpan] {
        let bytes = Array(text.utf8)
        if bytes != prev {
            // Non-append REWRITES — the incremental parser re-deriving a
            // block's flat text, e.g. `**bold` collapsing into a bold run —
            // keep the common prefix's committed fades and re-veil only the
            // changed tail. This happens constantly; without it every mend
            // flash would restart the whole paragraph's fade.
            let p = Self.commonPrefix(prev, bytes)
            chunks = chunks.compactMap { chunk in
                var chunk = chunk
                chunk.range = chunk.range.lowerBound..<min(chunk.range.upperBound, p)
                return chunk.range.lowerBound < chunk.range.upperBound ? chunk : nil
            }
            if bytes.count > p {
                // Cadence-adaptive duration: update the EMA with the gap since
                // the previous append.
                if let last = lastAppend {
                    let gap = max(0, now - last) * 1000
                    emaMS = Veil.nextEMA(emaMS, gapMS: gap)
                }
                lastAppend = now
                chunks.append(
                    Chunk(
                        range: p..<bytes.count,
                        started: now,
                        durationMS: Veil.duration(ema: emaMS)
                    )
                )
            }
            prev = bytes
        }
        // The boost is recomputed TWICE per advance — once to prune, once to
        // emit — exactly as `veil.rs:156-161` does. Pruning shrinks the active
        // count, which slows the survivors back down for this frame.
        var boost = Veil.boost(chunks: chunks.count)
        chunks.removeAll { chunk in
            let elapsed = max(0, now - chunk.started) * 1000
            return elapsed * boost >= chunk.durationMS
        }
        boost = Veil.boost(chunks: chunks.count)
        return chunks.map { chunk in
            let elapsed = max(0, now - chunk.started) * 1000
            let progress = min(max(elapsed * boost / chunk.durationMS, 0), 1)
            return SupermuxZeronVeilSpan(range: chunk.range, opacity: Veil.opacity(progress))
        }
    }

    /// Any chunk still fading, as of the last ``advance(text:now:)``?
    public var isFading: Bool { !chunks.isEmpty }

    /// Longest common prefix length, snapped back to a UTF-8 char boundary.
    ///
    /// The snap matters: `"é"` vs `"è"` share 0 bytes, not 1, and a split
    /// scalar would make the range unrepresentable as a `String.Index`.
    static func commonPrefix(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var p = 0
        let limit = min(a.count, b.count)
        while p < limit, a[p] == b[p] { p += 1 }
        // A UTF-8 continuation byte is `0b10xx_xxxx`; back up off one.
        while p > 0, p < b.count, b[p] & 0xC0 == 0x80 { p -= 1 }
        return p
    }
}

// MARK: - Row veil

/// Veil state for one live streaming row, keyed by the render tree's stable
/// per-element discriminator.
///
/// The key must be STABLE across appends — it is what keys the veil, the
/// flatten cache and (in zeron) the selection registry. The renderer's
/// discriminator scheme (`SupermuxZeronMarkdownBlock.elementID`) provides that:
/// the incremental parse only touches a suffix, so earlier elements keep their
/// ids.
public struct SupermuxZeronRowVeil: Sendable {
    private var elems: [Int: SupermuxZeronElemVeil] = [:]
    /// Attach pass in progress.
    private var seeding: Bool

    /// A veil that fades everything from empty — a row that appears mid-stream.
    public init() { seeding = false }

    /// A veil whose FIRST render pass seeds baselines instead of fading.
    ///
    /// Use this for rows that already carried text when the transcript
    /// (re)attached: switching back to an already-streaming session must not
    /// dissolve the entire existing reply (a zeron user report).
    public static func seeded() -> Self {
        var veil = Self()
        veil.seeding = true
        return veil
    }

    /// The attach pass is over — elements that appear from here on are newly
    /// streamed content and fade normally. Call immediately after the first
    /// render pass.
    public mutating func finishSeeding() { seeding = false }

    /// Advance one element and return its active spans.
    public mutating func advance(
        element: Int,
        text: String,
        now: TimeInterval
    ) -> [SupermuxZeronVeilSpan] {
        if seeding, elems[element] == nil {
            var baseline = SupermuxZeronElemVeil()
            baseline.seed(text)
            elems[element] = baseline
            return []
        }
        var veil = elems[element] ?? SupermuxZeronElemVeil()
        let spans = veil.advance(text: text, now: now)
        elems[element] = veil
        return spans
    }

    /// Any element still fading? Drives the once-per-frame repaint request.
    public var isFading: Bool { elems.values.contains(where: \.isFading) }

    /// Intersect spans with `[start, end)` and shift them to LOCAL offsets.
    ///
    /// Code blocks track the veil on the whole code text and slice per line, so
    /// a fading append dissolves line by line without breaking the exact
    /// `lines × 18` height.
    public static func slice(
        _ spans: [SupermuxZeronVeilSpan],
        from start: Int,
        to end: Int
    ) -> [SupermuxZeronVeilSpan] {
        spans.compactMap { span in
            let s = max(span.range.lowerBound, start)
            let e = min(span.range.upperBound, end)
            guard s < e else { return nil }
            return SupermuxZeronVeilSpan(range: (s - start)..<(e - start), opacity: span.opacity)
        }
    }

    /// The alpha covering a byte offset, or 1 when no span covers it.
    ///
    /// The renderer walks its runs through this rather than splitting them:
    /// SwiftUI/TextKit take the color per attribute range, so the "split runs
    /// at span boundaries" step of `apply_veil` is expressed as an attribute
    /// application over each span's range instead.
    public static func opacity(
        at offset: Int,
        in spans: [SupermuxZeronVeilSpan]
    ) -> Double {
        for span in spans where span.range.contains(offset) { return span.opacity }
        return 1
    }
}

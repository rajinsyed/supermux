import Foundation
import Testing
@testable import SupermuxZeronUI

/// The streaming fade's math and chunk bookkeeping, asserted case-for-case
/// against `veil.rs`'s own test module.
///
/// The veil is purely cosmetic, but the BOOKKEEPING is not: a chunk that fades
/// twice makes settled text re-dissolve on every keystroke, and a non-append
/// rewrite that drops the common prefix restarts the whole paragraph's fade
/// every time the parser resolves a marker.
struct SupermuxZeronVeilTests {
    private typealias Veil = SupermuxZeronMetrics.Veil

    // MARK: The pure math

    /// The mugen `FadePainter` constants, asserted equal — the same guard
    /// `fade_constants_match_mugen_fade_painter` provides upstream.
    @Test("fade constants match mugen's FadePainter")
    func fadeConstantsMatchMugen() {
        #expect(Veil.emaSeedMS == 160.0)
        #expect(Veil.minFadeMS == 120.0)
        #expect(Veil.maxFadeMS == 400.0)
        #expect(Veil.curvePow == 1.6)
        #expect(Veil.gapClampMS == 1000.0)
    }

    /// `duration = clamp(ema × 3, 120, 400)`, fixed at the chunk's arrival.
    @Test("duration clamps the tripled EMA")
    func durationClampsTripledEMA() {
        // The SEED EMA of 160 gives the very first chunk 480 → clamped to 400.
        #expect(Veil.duration(ema: 160) == 400)
        // A fast 30 ms-cadence stream lands on the 120 ms floor.
        #expect(Veil.duration(ema: 30) == 120)
        #expect(Veil.duration(ema: 60) == 180)
    }

    /// `ema' = ema × 0.7 + min(gap, 1000) × 0.3`.
    ///
    /// Compared with a tolerance, not for equality: `SupermuxZeronMetrics.Veil`
    /// spells the new-sample weight `(1 - emaRetain)`, and `1 - 0.7` is
    /// `0.30000000000000004` in binary floating point, not `0.3`. The
    /// difference is ~6e-14 ms on a fade duration — far below one frame at any
    /// refresh rate — so it is a spelling nit in the constants table, not a
    /// behavioural gap. Asserting exact equality here would encode the nit.
    @Test("the EMA clamps its gap at 1000 ms")
    func emaClampsGap() {
        #expect(abs(Veil.nextEMA(160, gapMS: 100) - (160 * 0.7 + 100 * 0.3)) < 1e-9)
        // A 5 s stall must not drag the EMA to its max.
        #expect(abs(Veil.nextEMA(160, gapMS: 5000) - (160 * 0.7 + 1000 * 0.3)) < 1e-9)
        // The clamp is what matters: a 5 s gap and a 1 s gap agree exactly.
        #expect(Veil.nextEMA(160, gapMS: 5000) == Veil.nextEMA(160, gapMS: 1000))
    }

    /// `boost = 1 + 0.3 × max(0, n − 2)` — a backed-up stream catches up
    /// instead of piling on.
    @Test("the fast-stream boost starts at the third concurrent chunk")
    func boostStartsAtThirdChunk() {
        #expect(Veil.boost(chunks: 0) == 1.0)
        #expect(Veil.boost(chunks: 2) == 1.0)
        #expect(abs(Veil.boost(chunks: 3) - 1.3) < 1e-9)
        #expect(abs(Veil.boost(chunks: 5) - 1.9) < 1e-9)
    }

    /// `textAlpha(p) = 1 − (1 − p)^1.6` — 0 at arrival, 1 when the veil is gone.
    @Test("the opacity curve is clamped, monotonic, and front-loaded")
    func opacityCurve() {
        #expect(Veil.opacity(0) == 0)
        #expect(Veil.opacity(1) == 1)
        let mid = Veil.opacity(0.5)
        #expect(mid > 0 && mid < 1)
        // The ^1.6 ease means text is ALREADY more than half visible at p=0.5 —
        // a fast reveal that lingers slightly at the end.
        #expect(mid > 0.5)
        #expect(abs(mid - (1 - pow(0.5, 1.6))) < 1e-9)
        #expect(Veil.opacity(0.2) <= Veil.opacity(0.4))
        #expect(Veil.opacity(-1) == 0)
        #expect(Veil.opacity(2) == 1)
    }

    // MARK: Chunk bookkeeping

    @Test("first text fades once and then settles for good")
    func firstTextFadesAndSettlesOnce() {
        var veil = SupermuxZeronElemVeil()
        let t0: TimeInterval = 1000

        let first = veil.advance(text: "hello", now: t0)
        #expect(first.count == 1)
        #expect(first[0].range == 0..<5)
        #expect(first[0].opacity == 0)

        let mid = veil.advance(text: "hello", now: t0 + 0.250)
        #expect(mid.count == 1)
        #expect(mid[0].opacity > 0 && mid[0].opacity < 1)

        // Past its 400 ms duration it is pruned and NEVER re-animates.
        #expect(veil.advance(text: "hello", now: t0 + 0.600).isEmpty)
        #expect(!veil.isFading)
        #expect(veil.advance(text: "hello", now: t0 + 0.700).isEmpty)
    }

    @Test("appended chunks fade concurrently and independently")
    func appendedChunksFadeIndependently() {
        var veil = SupermuxZeronElemVeil()
        let t0: TimeInterval = 1000

        _ = veil.advance(text: "one ", now: t0)
        let spans = veil.advance(text: "one two ", now: t0 + 0.100)
        #expect(spans.count == 2)
        #expect(spans[0].range == 0..<4)
        #expect(spans[1].range == 4..<8)
        // The OLDER chunk is further along its own fade than the newer one.
        #expect(spans[0].opacity > spans[1].opacity)

        // Once the first settles, only the newer chunk remains.
        let later = veil.advance(text: "one two ", now: t0 + 0.410)
        #expect(later.count == 1)
        #expect(later[0].range == 4..<8)
    }

    @Test("faded text never re-animates on a later append")
    func fadedTextNeverReanimates() {
        var veil = SupermuxZeronElemVeil()
        let t0: TimeInterval = 1000
        _ = veil.advance(text: "stable", now: t0)
        #expect(veil.advance(text: "stable", now: t0 + 0.600).isEmpty)

        let spans = veil.advance(text: "stable more", now: t0 + 0.700)
        #expect(spans.count == 1)
        // ONLY the new suffix.
        #expect(spans[0].range == 6..<11)
        #expect(spans[0].opacity == 0)
    }

    /// The key subtlety: a non-append rewrite — which happens constantly, e.g.
    /// `"intro **bol"` becoming `"intro bold"` when the parser resolves the
    /// emphasis — keeps the committed prefix's in-flight fade and re-veils only
    /// the changed tail.
    @Test("a non-append rewrite keeps the prefix and re-veils the tail")
    func nonAppendRewriteKeepsPrefix() {
        var veil = SupermuxZeronElemVeil()
        let t0: TimeInterval = 1000
        _ = veil.advance(text: "intro **bol", now: t0)

        let spans = veil.advance(text: "intro bold", now: t0 + 0.100)
        #expect(spans.count == 2)
        #expect(spans[0].range == 0..<6)
        #expect(spans[1].range == 6..<10)
        #expect(spans[0].opacity > spans[1].opacity)
    }

    /// `"é"` is `0xC3 0xA9` and `"è"` is `0xC3 0xA8` — a raw byte prefix would
    /// split the scalar and make the range unrepresentable.
    @Test("the common prefix snaps back to a char boundary")
    func commonPrefixRespectsCharBoundaries() {
        func prefix(_ a: String, _ b: String) -> Int {
            SupermuxZeronElemVeil.commonPrefix(Array(a.utf8), Array(b.utf8))
        }
        #expect(prefix("é", "è") == 0)
        #expect(prefix("abé", "abè") == 2)
        #expect(prefix("same", "same") == 4)
        #expect(prefix("", "new") == 0)
    }

    // MARK: Row-level seeding

    /// Switching back to a streaming session must NOT dissolve the whole
    /// existing reply — the text already on screen is the attach baseline.
    @Test("a seeded row adopts existing text without fading")
    func seededRowAdoptsWithoutFading() {
        var row = SupermuxZeronRowVeil.seeded()
        let t0: TimeInterval = 1000

        #expect(row.advance(element: 0, text: "already streamed text", now: t0).isEmpty)
        #expect(row.advance(element: 1, text: "second block", now: t0).isEmpty)
        #expect(!row.isFading)

        // Appends AFTER the attach fade normally — only the new suffix.
        let spans = row.advance(element: 0, text: "already streamed text plus", now: t0 + 0.100)
        #expect(spans.count == 1)
        #expect(spans[0].range == 21..<26)

        // The attach pass ends after the first render: elements first seen from
        // then on are newly streamed content and fade from empty.
        row.finishSeeding()
        let fresh = row.advance(element: 2, text: "new block", now: t0 + 0.200)
        #expect(fresh.count == 1)
        #expect(fresh[0].range == 0..<9)
    }

    @Test("a mid-stream row fades its first chunk")
    func defaultRowFadesFirstText() {
        var row = SupermuxZeronRowVeil()
        let spans = row.advance(element: 0, text: "fresh", now: 1000)
        #expect(spans.count == 1)
        #expect(spans[0].range == 0..<5)
        #expect(spans[0].opacity == 0)
    }

    // MARK: Slicing

    /// Code blocks track the veil on the WHOLE code text and slice per line, so
    /// a fading append dissolves line by line without breaking the exact
    /// `lines × 18` height.
    @Test("slicing intersects and shifts spans to local offsets")
    func sliceShiftsToLocalOffsets() {
        let spans = [
            SupermuxZeronVeilSpan(range: 0..<20, opacity: 0.4),
            SupermuxZeronVeilSpan(range: 30..<40, opacity: 0.1),
        ]
        // Line window [10, 35): the first span clips to [10,20) → local [0,10),
        // the second clips to [30,35) → local [20,25).
        let sliced = SupermuxZeronRowVeil.slice(spans, from: 10, to: 35)
        #expect(sliced.count == 2)
        #expect(sliced[0].range == 0..<10)
        #expect(sliced[0].opacity == 0.4)
        #expect(sliced[1].range == 20..<25)
        #expect(sliced[1].opacity == 0.1)

        // A window that misses everything yields nothing.
        #expect(SupermuxZeronRowVeil.slice(spans, from: 21, to: 29).isEmpty)
    }

    @Test("an uncovered offset reads full opacity")
    func uncoveredOffsetIsOpaque() {
        let spans = [SupermuxZeronVeilSpan(range: 4..<8, opacity: 0.25)]
        #expect(SupermuxZeronRowVeil.opacity(at: 0, in: spans) == 1)
        #expect(SupermuxZeronRowVeil.opacity(at: 5, in: spans) == 0.25)
        #expect(SupermuxZeronRowVeil.opacity(at: 8, in: spans) == 1)
        // A settled element returns no spans at all, so every offset is opaque
        // and the frame is byte-identical to a render with no veil.
        #expect(SupermuxZeronRowVeil.opacity(at: 5, in: []) == 1)
    }
}

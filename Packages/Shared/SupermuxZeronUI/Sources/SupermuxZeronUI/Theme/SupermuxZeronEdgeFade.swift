//
//  SupermuxZeronEdgeFade.swift
//  SupermuxZeronUI
//
//  The transcript's top/bottom fade band. Spec 02 §6, spec 01 §8.5, plan risk R2.
//
//  ── What zeron actually does, and why an overlay gradient is FORBIDDEN ──
//
//  `edge_fade.rs` wraps the child so its whole subtree paints inside a
//  `gpui::EdgeFade` scope: every painted primitive — glyphs, quads, images,
//  icons, shadows — fades by its VERTICAL DISTANCE to the wrapper's edges, at
//  per-glyph granularity. The comment at `edge_fade.rs:1-6` states the reason:
//
//  > Built for the GLASS sidebar's scroll fade: over a see-through blurred
//  > backdrop NO PAINTED OVERLAY CAN FADE CONTENT OUT, because "what is behind
//  > the window" is not a paintable color.
//
//  So: **never** `overlay(LinearGradient(colors: [background, .clear]))`. On the
//  macOS glass shell that paints a visible smear — exactly the failure the
//  shader exists to avoid. `.mask(LinearGradient)` is a true alpha mask on the
//  composited layer and is the faithful mapping.
//
//  ── The residual gap (R2) ──
//
//  gpui fades a glyph as a unit, sampled at its nearest-to-edge point, so a
//  glyph is never sliced mid-height. A SwiftUI mask cuts a glyph horizontally
//  through the middle. zeron's own mitigation applies here unchanged: the last
//  row self-pads by `bottomClearance + fadeBand + 8`, so SETTLED content is
//  never inside a band and the difference is observable only on mid-scroll
//  content passing through it, for a few frames.
//
//  ── Band geometry (spec 02 §6.3) ──
//
//    top     `insetTop` points fully CLEAR (the titlebar the transcript scrolls
//            under), then a `bandTop` ramp to fully opaque.
//    bottom  `max(stackHeight - statusStripHeight, 1)` — asymmetric and DYNAMIC:
//            opaque at the composer pill's top edge (the reserved 24 pt status
//            strip above it is empty air), zero at the underlay's bottom.
//
//  The fade is ALWAYS ON, never gated on measured scroll state: "the resting
//  paddings keep pinned content out of the bands, and gating on measured scroll
//  state left the top unfaded for one frame on session switch — user report."
//

public import SwiftUI

/// The transcript's edge-fade band geometry.
public struct SupermuxZeronEdgeFade: Sendable, Equatable, Hashable {
    /// Points at the top that paint fully transparent BEFORE the ramp starts —
    /// `Theme.titlebarHeight` on macOS, the safe-area top inset on iOS. Content
    /// vanishes before it can overlap the opaque chrome above.
    public var insetTop: CGFloat
    /// The top ramp height. `Theme.transcriptFadeBand` (24).
    public var bandTop: CGFloat
    /// The bottom ramp height. Dynamic — see ``bandBottom(stackHeight:safeAreaBottom:)``.
    public var bandBottom: CGFloat

    public init(insetTop: CGFloat, bandTop: CGFloat, bandBottom: CGFloat) {
        self.insetTop = insetTop
        self.bandTop = bandTop
        self.bandBottom = bandBottom
    }

    /// The macOS default: the fade under the unified titlebar.
    public static func macOS(stackHeight: CGFloat) -> SupermuxZeronEdgeFade {
        SupermuxZeronEdgeFade(
            insetTop: SupermuxZeronMetrics.Theme.titlebarHeight,
            bandTop: SupermuxZeronMetrics.Theme.transcriptFadeBand,
            bandBottom: bandBottom(stackHeight: stackHeight)
        )
    }

    /// The iOS default: the safe-area top replaces the titlebar, and the bottom
    /// band grows by the bottom safe-area inset exactly as the last row's pad
    /// does (plan §4).
    public static func iOS(
        stackHeight: CGFloat,
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat
    ) -> SupermuxZeronEdgeFade {
        SupermuxZeronEdgeFade(
            insetTop: safeAreaTop,
            bandTop: SupermuxZeronMetrics.Theme.transcriptFadeBand,
            bandBottom: bandBottom(stackHeight: stackHeight, safeAreaBottom: safeAreaBottom)
        )
    }

    /// `max(stackHeight - statusStripHeight, 1)`, plus any bottom safe area.
    ///
    /// `stackHeight` is the measured composer + status-strip stack the
    /// transcript scrolls under (the terminal dock is excluded upstream: the
    /// dock is not glass the transcript may slide under — transcript text
    /// ghosted through the terminal grid, user report).
    public static func bandBottom(
        stackHeight: CGFloat,
        safeAreaBottom: CGFloat = 0
    ) -> CGFloat {
        max(stackHeight - SupermuxZeronMetrics.Theme.statusStripHeight, 1) + safeAreaBottom
    }

    /// The mask gradient for a viewport of `height`.
    ///
    /// Stops are expressed as fractions so the gradient stays correct through a
    /// live resize without re-laying-out the subtree. Guards degenerate heights
    /// (a zero-height viewport during first layout would divide by zero and
    /// paint the whole transcript transparent).
    public func mask(height: CGFloat) -> LinearGradient {
        guard height > 0 else {
            return LinearGradient(
                stops: [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Clamp so a tall chrome stack on a short viewport cannot invert the
        // stop order, which renders as a fully-masked (invisible) transcript.
        let clearTop = min(max(insetTop, 0), height) / height
        let opaqueTop = min(max(insetTop + bandTop, 0), height) / height
        let opaqueBottom = min(max(height - bandBottom, 0), height) / height
        let stops: [Gradient.Stop] = [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0), location: clearTop),
            .init(color: .black, location: max(opaqueTop, clearTop)),
            .init(color: .black, location: max(opaqueBottom, max(opaqueTop, clearTop))),
            .init(color: .black.opacity(0), location: 1),
        ]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

public extension View {
    /// Applies the zeron transcript edge fade.
    ///
    /// A `.mask`, never an overlay — see this file's header.
    func supermuxZeronEdgeFade(_ fade: SupermuxZeronEdgeFade) -> some View {
        modifier(SupermuxZeronEdgeFadeModifier(fade: fade))
    }
}

private struct SupermuxZeronEdgeFadeModifier: ViewModifier {
    let fade: SupermuxZeronEdgeFade

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                Rectangle().fill(fade.mask(height: proxy.size.height))
            }
        }
    }
}

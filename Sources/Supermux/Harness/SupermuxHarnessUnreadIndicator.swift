import SwiftUI

/// The harness pane's unread treatment: a short, soft-glowing accent tick on
/// the pane's leading edge that breathes slowly.
///
/// **Why not the outline.** Upstream marks an unread pane by stroking a ring
/// around the whole surface (`GhosttyTerminalView`'s `notificationRingLayer`,
/// driven by `showsUnreadNotificationRing`). That renderer lives inside the
/// AppKit terminal portal — one of the typing-latency-sensitive paths — and
/// only terminals mount it, which is why a harness pane never showed anything.
/// Rather than teaching that layer about WKWebView panes, the harness pane
/// draws its own indicator here, in the supermux layer.
///
/// **Why a tick.** A 2.5pt ring around a chat surface reads as an error state
/// and fights the pane's own rounded chrome. One short vertical mark, hugging
/// the leading edge and vertically centered, says "this pane moved" without
/// boxing the content: it occupies ~4pt of gutter no reader is using, never
/// overlaps the transcript, and stays legible over both light and dark web
/// content because it carries its own glow. The breathing is deliberately slow
/// and shallow (a 2.6s ease-in-out between 0.55 and 1.0 opacity) — enough to
/// catch peripheral vision on a glance across a split, quiet enough to ignore
/// while reading. Colour is the workspace attention colour, which defaults to
/// the fork's vermilion accent and honours the user's configured pane-flash
/// colour, so the indicator matches every other attention mark in the app.
struct SupermuxHarnessUnreadIndicator: View {
    /// Whether the pane currently carries an unread indicator.
    let isUnread: Bool
    /// The resolved attention colour (configured pane-flash colour, else accent).
    let attentionColor: Color

    @State private var isBreathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Metrics {
        static let width: CGFloat = 3
        static let height: CGFloat = 28
        static let leadingInset: CGFloat = 3
        static let glowRadius: CGFloat = 5
        static let restingOpacity: Double = 0.55
        static let breathDuration: Double = 2.6
    }

    var body: some View {
        // `allowsHitTesting(false)` everywhere: the tick sits above a WKWebView
        // and must never swallow a click meant for the transcript.
        Capsule(style: .continuous)
            .fill(attentionColor)
            .frame(width: Metrics.width, height: Metrics.height)
            .shadow(color: attentionColor.opacity(0.55), radius: Metrics.glowRadius)
            .opacity(currentOpacity)
            .padding(.leading, Metrics.leadingInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { startBreathingIfNeeded() }
            .onChange(of: isUnread) { _, _ in startBreathingIfNeeded() }
            .onChange(of: reduceMotion) { _, _ in startBreathingIfNeeded() }
    }

    private var currentOpacity: Double {
        guard isUnread else { return 0 }
        if reduceMotion { return 1 }
        return isBreathing ? 1 : Metrics.restingOpacity
    }

    /// Starts (or stops) the breath. Called from lifecycle callbacks, never
    /// from `body` — a state write during body evaluation is the AttributeGraph
    /// hazard called out in CLAUDE.md.
    private func startBreathingIfNeeded() {
        guard isUnread, !reduceMotion else {
            isBreathing = false
            return
        }
        guard !isBreathing else { return }
        withAnimation(
            .easeInOut(duration: Metrics.breathDuration).repeatForever(autoreverses: true)
        ) {
            isBreathing = true
        }
    }
}

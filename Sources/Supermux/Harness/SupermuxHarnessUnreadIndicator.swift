import SwiftUI

/// Which side of the appearance divide the harness pane is being drawn on.
///
/// Deliberately its own type rather than `SwiftUI.ColorScheme`, for two
/// reasons: the source of truth is the pane's terminal background rather than
/// the system appearance (see `init(isDark:)`), and keeping the presentation
/// model below built on a plain value makes it assertable in tests without
/// standing up a view hierarchy.
enum SupermuxHarnessUnreadAppearance: Equatable {
    case light
    case dark

    /// Resolved from the pane's own theme, never from `Environment(\.colorScheme)`.
    /// A harness pane's darkness follows its terminal background colour, so a
    /// dark Ghostty theme under a Light system appearance is a *dark* pane —
    /// exactly the case the system colour scheme would get backwards.
    init(isDark: Bool) {
        self = isDark ? .dark : .light
    }
}

/// The resolved look of the harness pane's unread treatment.
///
/// Everything the indicator draws is derived from three numbers, so the design
/// intent — "legible in both appearances, and Reduce Motion loses the arrival
/// gesture but never the indicator" — is assertable without rendering a view.
struct SupermuxHarnessUnreadPresentation: Equatable, Sendable {
    /// Contract floors. The indicator exists to be noticed from across a split;
    /// any future tuning that drops below these is a regression, not a taste
    /// change, and the tests say so.
    static let seamLegibilityFloor: Double = 0.8
    static let glowLegibilityFloor: Double = 0.16

    /// Resting geometry. The glow is intentionally large and faint rather than
    /// small and loud — that is what separates "premium" from "error state".
    static let seamHeight: CGFloat = 1.5
    static let glowHeight: CGFloat = 72
    /// The glow enters this much taller and retracts to its resting height.
    /// Constant across states on purpose: the hidden state parks the glow at
    /// the entry scale so an arrival animates 1.6 -> 1.0 rather than collapsing
    /// into a no-op when `isUnread` and the animation land in one transaction.
    static let entryGlowScale: CGFloat = 1.6
    /// Matches `PanelOverlayRingMetrics.cornerRadius`, the radius upstream's
    /// pane overlay ring uses, so the light follows the same pane silhouette.
    static let paneCornerRadius: CGFloat = 6

    /// Opacity of the crisp hairline at the pane's very top edge.
    let seamOpacity: Double
    /// Peak opacity of the gradient bleeding down from that hairline.
    let glowOpacity: Double
    /// Duration of the one-shot arrival settle. Zero means "no motion".
    let entryDuration: Double

    var isVisible: Bool { seamOpacity > 0 }
    var animatesOnArrival: Bool { entryDuration > 0 }

    static func resolve(
        isUnread: Bool,
        appearance: SupermuxHarnessUnreadAppearance,
        reduceMotion: Bool
    ) -> SupermuxHarnessUnreadPresentation {
        guard isUnread else {
            return SupermuxHarnessUnreadPresentation(
                seamOpacity: 0,
                glowOpacity: 0,
                entryDuration: 0
            )
        }
        // Dark panes carry more bloom: the harness surface is translucent and
        // vibrancy-blurred, so a faint wash loses more contrast there than the
        // same wash does over a light surface, where the crisp seam carries it.
        switch appearance {
        case .dark:
            return SupermuxHarnessUnreadPresentation(
                seamOpacity: 0.92,
                glowOpacity: 0.26,
                entryDuration: reduceMotion ? 0 : 1.15
            )
        case .light:
            return SupermuxHarnessUnreadPresentation(
                seamOpacity: 1.0,
                glowOpacity: 0.2,
                entryDuration: reduceMotion ? 0 : 1.15
            )
        }
    }
}

/// The harness pane's unread treatment: light spilling in over the pane's top
/// edge, settling once and then holding perfectly still.
///
/// **Why not the outline.** Upstream marks an unread pane by stroking a ring
/// around the whole surface (`GhosttyTerminalView`'s `notificationRingLayer`,
/// driven by `showsUnreadNotificationRing`). That renderer lives inside the
/// AppKit terminal portal — one of the typing-latency-sensitive paths — and
/// only terminals mount it, which is why a harness pane never showed anything.
/// Rather than teaching that layer about WKWebView panes, the harness pane
/// draws its own indicator here, in the supermux layer.
///
/// **Why an edge light.** The previous attempt was a 3x28pt tick on the leading
/// edge that pulsed forever. It failed twice over: a 3pt mark is a rounding
/// error in a pane hundreds of points wide, and a permanent pulse reads as
/// something still happening — the opposite of the message. What we actually
/// need to say is *"work finished here while you were away"*, which is a past
/// event leaving a residue. So: a hairline seam across the pane's top edge with
/// a soft luminous bleed falling ~72pt beneath it, concentrated toward the
/// horizontal centre and fading out at the corners. Large and faint instead of
/// small and loud, which is the whole difference between premium and alarming.
/// It spans the full pane, so it is unmissable at a glance across a split, yet
/// it lives entirely in the top few percent of the surface and never obscures a
/// line of transcript.
///
/// **Why one shot.** On arrival the glow pours in taller and brighter and eases
/// down into its resting height over 1.15s — the settle *is* the notification.
/// After that it is completely static: no repeating animation, no timer, no
/// display link, nothing per-frame (see the typing-latency policy in
/// CLAUDE.md). A still, lit edge is calmer to sit next to than a pulse and just
/// as findable, because discovery here happens when the user's eyes come back
/// to the window, not while they are staring at it.
///
/// Colour is the workspace attention colour, so the indicator honours the
/// user's configured pane-flash colour and matches every other attention mark
/// in the app.
struct SupermuxHarnessUnreadIndicator: View {
    /// Whether the pane currently carries an unread indicator.
    let isUnread: Bool
    /// The resolved attention colour (configured pane-flash colour, else accent).
    let attentionColor: Color
    /// The pane's own appearance, resolved from its terminal background by
    /// `AgentSessionWebTheme` — the same signal the transcript styles itself
    /// from, so the indicator never disagrees with the surface beneath it.
    let appearance: SupermuxHarnessUnreadAppearance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasSettled = false

    private var presentation: SupermuxHarnessUnreadPresentation {
        .resolve(isUnread: isUnread, appearance: appearance, reduceMotion: reduceMotion)
    }

    var body: some View {
        // `allowsHitTesting(false)`: this sits above a WKWebView and must never
        // swallow a click meant for the transcript.
        ZStack(alignment: .top) {
            glow
            seam
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mask { horizontalFalloff }
        // Follows the pane's own rounded chrome so the seam never squares off a
        // corner the surface underneath has rounded.
        .clipShape(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessUnreadPresentation.paneCornerRadius,
                style: .continuous
            )
        )
        .opacity(hasSettled ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { updateSettle() }
        .onChange(of: isUnread) { _, _ in updateSettle() }
        .onChange(of: reduceMotion) { _, _ in updateSettle() }
    }

    /// The soft bleed. Scales only vertically, anchored to the top edge, so the
    /// arrival reads as light spilling in over the pane's rim.
    private var glow: some View {
        LinearGradient(
            stops: [
                .init(color: attentionColor.opacity(presentation.glowOpacity), location: 0),
                .init(color: attentionColor.opacity(presentation.glowOpacity * 0.45), location: 0.35),
                .init(color: attentionColor.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: SupermuxHarnessUnreadPresentation.glowHeight)
        .scaleEffect(
            x: 1,
            y: hasSettled ? 1 : SupermuxHarnessUnreadPresentation.entryGlowScale,
            anchor: .top
        )
    }

    /// The definite edge. Without it the glow alone could pass for a background
    /// gradient; the hairline is what makes the state unambiguous.
    private var seam: some View {
        Rectangle()
            .fill(attentionColor.opacity(presentation.seamOpacity))
            .frame(height: SupermuxHarnessUnreadPresentation.seamHeight)
            .shadow(color: attentionColor.opacity(presentation.glowOpacity * 1.8), radius: 5, y: 1)
    }

    /// Fades the treatment toward the pane's left and right ends so it reads as
    /// a light source rather than a warning bar, while staying strong enough at
    /// the extremes that the seam still spans the pane.
    private var horizontalFalloff: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.35), location: 0),
                .init(color: .white, location: 0.18),
                .init(color: .white, location: 0.82),
                .init(color: .white.opacity(0.35), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Drives the one-shot settle. Called from lifecycle callbacks, never from
    /// `body` — a state write during body evaluation is the AttributeGraph
    /// hazard called out in CLAUDE.md.
    private func updateSettle() {
        let resolved = presentation
        guard resolved.isVisible else {
            // Dismissal is instant and unanimated by design: it fires when the
            // user focuses or types into the pane, so they are already looking
            // here and a lingering fade would just be latency. Resetting also
            // rearms the settle, so the next arrival plays it instead of
            // popping in.
            hasSettled = false
            return
        }
        guard !hasSettled else { return }
        guard resolved.animatesOnArrival else {
            // Reduce Motion: land directly on the resting state. The indicator
            // itself is unchanged; only the arrival gesture is dropped.
            hasSettled = true
            return
        }
        withAnimation(.easeOut(duration: resolved.entryDuration)) {
            hasSettled = true
        }
    }
}

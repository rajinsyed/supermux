//
//  SupermuxZeronJumpPill.swift
//  SupermuxZeronUI
//
//  The "Scroll to bottom" pill. Spec 02 §7, spec 07 §4.3.
//
//  | Property        | Value                                                    |
//  |-----------------|----------------------------------------------------------|
//  | height          | 30, `rounded_full` → radius 15                            |
//  | padding         | leading 11, trailing 13, gap 6                            |
//  | border          | 1 pt `theme.border`                                       |
//  | shadow          | gpui `shadow_md` ≈ Tailwind's two-layer recipe            |
//  | background      | `surfaceRaised`, OPAQUE (`#1E1E1E` dark, pixel-verified)  |
//  | hover           | `surfaceRaisedHover`, a 150 ms EASE_TAILWIND blend        |
//  | contents        | `"↓"` 13 pt `textMuted`, `"Scroll to bottom"` 13 pt `text`|
//  | entrance        | `DIALOG_IN` — 180 ms EASE, opacity 0→1 plus a 2 pt rise   |
//  | exit            | none; the element is dropped                              |
//
//  ── Two constraints from the source ──
//
//  1. **The pill must paint OVER the bottom fade band.** In zeron it is rendered
//     by the shell as a LATER SIBLING of the faded transcript outlet, because an
//     overlay inside the fade's scope would be tinted by it (`shell.rs:4961-4964`).
//     The SwiftUI equivalent: mount it outside the `.supermuxZeronEdgeFade`
//     modifier, i.e. as an overlay on the container that HOLDS the faded
//     transcript, never on the transcript itself.
//
//  2. **Hover BRIGHTENS an opaque plate; it never becomes a translucent wash.**
//     A 10 %-alpha background here made the pill go see-through (user-reported,
//     `shell.rs:4689-4692`). In light mode the relationship inverts and the
//     opaque pill darkens — which the two `surfaceRaised*` tokens already encode.
//
//  ── Trigger (owned by the host, restated here so the two cannot drift) ──
//
//      show = distance > 320  AND NOT pinned          (AND NOT anchor.held)
//
//  and it is recomputed ONLY in the user-input scroll callback: programmatic
//  scrolls never re-enter it. See `SupermuxZeronStickSpring.showsJumpPill`.
//

public import SwiftUI

/// The floating scroll-to-bottom pill.
public struct SupermuxZeronJumpPill: View {
    private let theme: SupermuxZeronTheme
    private let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(theme: SupermuxZeronTheme, action: @escaping () -> Void) {
        self.theme = theme
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SupermuxZeronMetrics.Transcript.jumpPillGap) {
                // A literal glyph, not an icon font — zeron ships U+2193 as text
                // so it inherits the label's optical size exactly.
                Text(verbatim: "\u{2193}")
                    .font(
                        SupermuxZeronFonts.sans(
                            size: SupermuxZeronMetrics.Transcript.jumpPillTextSize
                        )
                    )
                    .foregroundStyle(theme.textMuted)
                Text(Self.label)
                    .font(
                        SupermuxZeronFonts.sans(
                            size: SupermuxZeronMetrics.Transcript.jumpPillTextSize
                        )
                    )
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, SupermuxZeronMetrics.Transcript.jumpPillPadLeading)
            .padding(.trailing, SupermuxZeronMetrics.Transcript.jumpPillPadTrailing)
            .frame(height: SupermuxZeronMetrics.Transcript.jumpPillHeight)
            .background(
                RoundedRectangle(
                    cornerRadius: SupermuxZeronMetrics.Transcript.jumpPillRadius,
                    style: .continuous
                )
                .fill(isHovered ? theme.surfaceRaisedHover : theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: SupermuxZeronMetrics.Transcript.jumpPillRadius,
                    style: .continuous
                )
                .strokeBorder(theme.border, lineWidth: 1)
            )
            // gpui `shadow_md`'s exact constants are UNKNOWN (the gpui fork is
            // unvendored); this is Tailwind's two-layer `shadow-md` recipe,
            // which the preset mirrors. Flagged approximate in the plan (R13).
            .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 4)
            .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 2)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: SupermuxZeronMetrics.Transcript.jumpPillRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovered = $0 }
        // 150 ms EASE_TAILWIND — the Tailwind `transition-colors` default, which
        // is what zeron's `hover_blend` reproduces. Hover is macOS-only, and a
        // hovered pill is on screen by definition, so the LazyVStack identity-
        // churn hazard does not apply here.
        .animation(
            reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
            value: isHovered
        )
        #endif
        // DIALOG_IN: opacity plus a 2 pt rise. Applied by the host as a
        // transition on the pill's presence, so a `.transition` here would
        // double up; the rise lives in ``transition``.
        .accessibilityLabel(Text(Self.label))
    }

    /// The pill's `DIALOG_IN` transition. Apply it where the pill is mounted:
    ///
    /// ```swift
    /// if showsJumpPill {
    ///     SupermuxZeronJumpPill(theme: theme, action: jump)
    ///         .transition(SupermuxZeronJumpPill.transition)
    /// }
    /// ```
    public static var transition: AnyTransition {
        .opacity.combined(
            with: .offset(y: SupermuxZeronMetrics.Motion.dialogInRise)
        )
    }

    /// The `DIALOG_IN` animation to wrap the presence change in.
    public static var presenceAnimation: Animation {
        SupermuxZeronMetrics.Motion.dialogIn.animation
    }

    public static let label = String(
        localized: "supermux.zeron.transcript.scrollToBottom",
        defaultValue: "Scroll to bottom",
        bundle: .supermuxZeronUI
    )
}

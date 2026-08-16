//
//  SupermuxZeronEmptyCanvas.swift
//  SupermuxZeronUI
//
//  The three empty states. Spec 02 §8, plan §1.5 (`FADE_IN`).
//
//  ── The three canvases (`shell.rs:4429–4523`) ──
//
//  1. **Blank** — a selected session with zero messages. Deliberately *nothing*:
//     no placeholder, no watermark, no text, just the frost backdrop with the
//     composer below it. Resisting the urge to put something here is the design.
//  2. **New session** — nothing selected yet. A centered column: watermark,
//     the target selectors at +16, and a helper line at +12 / 14 pt /
//     `textMuted @ 0.6`.
//  3. **Onboarding** — nothing to work in at all. A fainter watermark
//     (**0.09**, not 0.2 — the source flips it deliberately), a 16 pt MEDIUM
//     `theme.text` title at +24, a 13 pt `textMuted @ 0.7` subtitle at +6, and
//     `btn_primary` at +20.
//
//  All three are wrapped in `FADE_IN`: 500 ms `EASE_OUT_EXPO`, opacity 0→1
//  **plus a 4 pt rise** (`top: 4 → 0`). The curve is violently front-loaded —
//  97.2 % is done by 250 ms — which is why the rise reads as "already there"
//  rather than as a slide. Reduce Motion snaps a oneshot to its END state
//  (spec 07 §6), so the content simply appears in place.
//
//  ── The watermark ──
//
//  zeron paints `icons::ZERON_LOGO` at 41.9 × 48. That is zeron's own brand
//  mark, and this port ships no third-party brand marks (plan §6.4 — "Default:
//  ship none"). The mark is therefore an injectable slot: the geometry, the
//  0.2 / 0.09 alphas and every offset around it are preserved exactly, and the
//  shell supplies its own mark or none at all.
//

public import SwiftUI

// MARK: - Canvas

/// One of zeron's three empty canvases.
///
/// The whole surface is passive — no store reference, no state written from
/// `body` — so it is safe below a lazy boundary (cmux #2586).
public struct SupermuxZeronEmptyCanvas<Mark: View, Accessory: View>: View {
    /// Which canvas to paint.
    public enum Kind: Sendable, Equatable, Hashable {
        /// A live session with no messages yet. Renders **nothing**.
        case blank
        /// No session selected: watermark + accessory + helper line.
        case newSession
        /// Nothing to work in: fainter watermark + title + subtitle + action.
        case onboarding
    }

    private let kind: Kind
    private let theme: SupermuxZeronTheme
    private let title: String?
    private let subtitle: String?
    private let helper: String?
    private let mark: Mark
    private let accessory: Accessory
    private let action: (label: String, perform: () -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    /// - Parameters:
    ///   - kind: which canvas.
    ///   - theme: the appearance-keyed palette.
    ///   - title: onboarding only — 16 pt MEDIUM `theme.text` at +24.
    ///   - subtitle: onboarding only — 13 pt `textMuted @ 0.7` at +6.
    ///   - helper: new-session only — 14 pt `textMuted @ 0.6` at +12.
    ///   - action: onboarding only — `btn_primary` at +20.
    ///   - mark: the watermark. 41.9 × 48 in zeron; alpha is applied here
    ///     (0.2 for `.newSession`, 0.09 for `.onboarding`), so pass an
    ///     untinted glyph.
    ///   - accessory: new-session only — the target selectors, at +16.
    public init(
        kind: Kind,
        theme: SupermuxZeronTheme,
        title: String? = nil,
        subtitle: String? = nil,
        helper: String? = nil,
        action: (label: String, perform: () -> Void)? = nil,
        @ViewBuilder mark: () -> Mark = { EmptyView() },
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.kind = kind
        self.theme = theme
        self.title = title
        self.subtitle = subtitle
        self.helper = helper
        self.action = action
        self.mark = mark()
        self.accessory = accessory()
    }

    /// zeron's watermark box, kept even though the mark itself is injected —
    /// every offset below is measured from it.
    public static var markSize: CGSize { CGSize(width: 41.9, height: 48) }

    public var body: some View {
        Group {
            switch kind {
            case .blank:
                // Deliberately empty. See the header.
                Color.clear
            case .newSession:
                column {
                    watermark(alpha: 0.2)
                    accessory.padding(.top, 16)
                    if let helper {
                        Text(helper)
                            .font(SupermuxZeronFonts.sans(size: 14))
                            .foregroundStyle(theme.textMuted.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }
                }
            case .onboarding:
                column {
                    // 0.09, NOT 0.2 — the onboarding mark is deliberately
                    // fainter than the new-session one.
                    watermark(alpha: 0.09)
                    if let title {
                        Text(title)
                            .font(SupermuxZeronFonts.sans(size: 16, weight: .medium))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.center)
                            .padding(.top, 24)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(SupermuxZeronFonts.sans(size: 13))
                            .foregroundStyle(theme.textMuted.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                    }
                    if let action {
                        SupermuxZeronPrimaryButton(
                            theme: theme,
                            label: action.label,
                            action: action.perform
                        )
                        .padding(.top, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The centered column, wrapped in `FADE_IN`.
    ///
    /// The fade is driven by a one-shot `hasAppeared` flip rather than a
    /// `.transition`, because this canvas is not inserted into a container that
    /// would animate its insertion — `.onAppear` is the only "mount" signal
    /// SwiftUI gives a root-level view. Reduce Motion sets the flag without an
    /// animation, which snaps the oneshot to its END state.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .opacity(hasAppeared ? 1 : 0)
        // top: 4 → 0.
        .offset(y: hasAppeared ? 0 : SupermuxZeronMetrics.Motion.fadeInRise)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(SupermuxZeronMetrics.Motion.fadeIn.animation) {
                    hasAppeared = true
                }
            }
        }
    }

    private func watermark(alpha: Double) -> some View {
        mark
            .frame(width: Self.markSize.width, height: Self.markSize.height)
            .foregroundStyle(theme.text.opacity(alpha))
            .accessibilityHidden(true)
    }
}

// MARK: - Primary button

/// `popover::btn_primary` (`popover.rs:943–955`): px 12, py 6, r 8, filled with
/// `theme.text` and lettered in `theme.onSolid` at 13 pt MEDIUM.
///
/// The inverted fill is the point — it is the one loud control in a design that
/// is otherwise entirely washes. Hover dims the whole button to 0.9 rather than
/// swapping the fill.
public struct SupermuxZeronPrimaryButton: View {
    private let theme: SupermuxZeronTheme
    private let label: String
    private let action: () -> Void

    @State private var isHovered = false

    public init(theme: SupermuxZeronTheme, label: String, action: @escaping () -> Void) {
        self.theme = theme
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(SupermuxZeronFonts.sans(size: 13, weight: .medium))
                .foregroundStyle(theme.onSolid)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.text)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 0.9 : 1)
        .onHover { isHovered = $0 }
        .animation(SupermuxZeronMetrics.Motion.hoverFade.animation, value: isHovered)
    }
}

// MARK: - Secondary button

/// The quiet counterpart: same box, but a 1 pt `theme.border` over an `ink(0)`
/// fill and `theme.text` lettering. zeron's `retry_row` Retry button
/// (`pickers.rs:2424–2457`) at px 8 / py 3 / r 6 is the same recipe one step
/// smaller; this is the dialog-scale seat.
public struct SupermuxZeronSecondaryButton: View {
    private let theme: SupermuxZeronTheme
    private let label: String
    private let action: () -> Void

    @State private var isHovered = false

    public init(theme: SupermuxZeronTheme, label: String, action: @escaping () -> Void) {
        self.theme = theme
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(SupermuxZeronFonts.sans(size: 13, weight: .medium))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        // Resting fill is ink(0) — white at zero alpha — never
                        // `Color.clear`, or the hover fade flashes grey.
                        .fill(isHovered ? theme.elementHover : theme.ink(0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(SupermuxZeronMetrics.Motion.hoverFade.animation, value: isHovered)
    }
}

// MARK: - Grid backdrop

/// The grid behind an empty canvas (`shell.rs:5881–5935`).
///
/// 1 pt `hairline(0.035)` lines on a 44 pt step over `theme.bg`, faded back into
/// the background toward the top (120 pt) and bottom (260 pt) edges. zeron's own
/// comment calls the two gradients a "mask approximation" of an ellipse at
/// 50 % / 40 %, so this reproduces the approximation, not the ellipse.
///
/// Drawn in a `Canvas` rather than as ~120 stacked `Rectangle`s: the source
/// spans 2640 pt, and that many views under an empty state is a real cost for a
/// backdrop nobody looks at.
public struct SupermuxZeronGridBackdrop: View {
    private let theme: SupermuxZeronTheme

    public init(theme: SupermuxZeronTheme) {
        self.theme = theme
    }

    private typealias T = SupermuxZeronMetrics.Theme

    /// The four mask-approximation bands (`shell.rs:5911–5963`). Local rather
    /// than in `SupermuxZeronMetrics` because this is the only surface that
    /// paints a grid, and the metrics table is a shared W0 file.
    private static let fadeTop: CGFloat = 120
    private static let fadeBottom: CGFloat = 260
    private static let fadeSide: CGFloat = 200

    public var body: some View {
        let line = theme.hairline(T.gridBackdropAlpha)
        Canvas { context, size in
            var x = T.gridBackdropStep
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                    with: .color(line)
                )
                x += T.gridBackdropStep
            }
            var y = T.gridBackdropStep
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(line)
                )
                y += T.gridBackdropStep
            }
        }
        .background(theme.bg)
        // FOUR edge gradients, not two: `grid_backdrop` fades the grid back into
        // the page on every side — 120 top, 260 bottom, and 200 on BOTH flanks
        // (`shell.rs:5911–5963`). Dropping the flanks leaves the vertical rules
        // running hard into the window edge, which is exactly what the mask
        // approximation exists to prevent.
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [theme.bg, theme.bg.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.fadeTop)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [theme.bg, theme.bg.opacity(0)],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: Self.fadeBottom)
        }
        .overlay(alignment: .leading) {
            LinearGradient(
                colors: [theme.bg, theme.bg.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.fadeSide)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [theme.bg, theme.bg.opacity(0)],
                startPoint: .trailing,
                endPoint: .leading
            )
            .frame(width: Self.fadeSide)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

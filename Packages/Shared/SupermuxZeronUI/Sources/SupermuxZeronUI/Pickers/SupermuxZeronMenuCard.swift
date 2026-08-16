//
//  SupermuxZeronMenuCard.swift
//  SupermuxZeronUI
//
//  The Traits menu — the picker's sibling on the same chip cluster.
//  Spec 08 §1.11, plan §0.4.
//
//  zeron's traits popover exposes a reasoning ladder plus every model option as
//  headed sections of menu rows. supermux's ladder is effort / fast mode /
//  thinking budget (plan §0.4), rendered through the identical primitives:
//  a 240 pt flush card with a manual 4 pt inset, `menu_heading` sections at a
//  2 pt row gap, and `menu_row` at px 8 / py 6 / r 8 / 13 pt.
//
//  Two details that look like polish and are not:
//
//  * **The 2 pt row gap.** Without it "adjacent hover/selected washes fuse into
//    one blob" (`pickers.rs:3059`, user report).
//  * **`menu_separator` is full-bleed** at mx −4, cancelling the card's own 4 pt
//    inset, so section rules span the card edge to edge.
//
//  Selecting keeps the menu open for multi-adjust (`pickers.rs:3038`) — unlike
//  the model picker, which dismisses.
//
//  ── Tracking, not hair spaces ──
//
//  zeron's `menu_heading` inserts a U+200A HAIR SPACE between every character
//  because gpui had no letter-spacing at the pinned revision. SwiftUI has real
//  tracking, so this uses `.tracking(1.0)` — 0.1em × 10 pt, which is what zeron
//  actually wanted. Porting the hair spaces would break VoiceOver and text
//  selection.
//

public import SwiftUI

// MARK: - Card

/// The flush menu card that hosts ``SupermuxZeronMenuSection``s.
///
/// Width 240 (`popover_frame_flush`, `pickers.rs:3514`) with the p-1 inset
/// applied manually inside, so a full-bleed separator can cancel it.
public struct SupermuxZeronMenuCard<Content: View>: View {
    private let theme: SupermuxZeronTheme
    private let width: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - width: 240 for the traits menu; the model picker uses its own 360 pt
    ///     card, which is a different view.
    public init(
        theme: SupermuxZeronTheme,
        width: CGFloat = 240,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.width = width
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        // `render_traits_sections` closes on `pb 2`.
        .padding(.bottom, 2)
        .padding(4)
        .frame(width: width, alignment: .leading)
        .background(SupermuxZeronGlassBackdrop(theme: theme, role: .menu))
        .clipShape(
            RoundedRectangle(
                cornerRadius: SupermuxZeronMetrics.Pickers.cardRadius, style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: SupermuxZeronMetrics.Pickers.cardRadius, style: .continuous
            )
            .strokeBorder(theme.hairline(0.10), lineWidth: 1)
        )
    }
}

// MARK: - Section

/// A `menu_heading` plus its rows at the 2 pt rhythm.
public struct SupermuxZeronMenuSection<Content: View>: View {
    private let theme: SupermuxZeronTheme
    private let heading: String
    private let content: Content

    public init(
        theme: SupermuxZeronTheme,
        heading: String,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.heading = heading
        self.content = content()
    }

    private typealias M = SupermuxZeronMetrics.Pickers

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading.uppercased())
                .font(SupermuxZeronFonts.sans(size: M.menuHeadingTextSize, weight: .medium))
                .tracking(M.menuHeadingTracking)
                .foregroundStyle(theme.textMuted.opacity(M.menuHeadingTextAlpha))
                .padding(.horizontal, M.menuHeadingPadX)
                .padding(.top, M.menuHeadingPadTop)
                .padding(.bottom, M.menuHeadingPadBottom)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Separator

/// `menu_separator` (`popover.rs:715–719`): h 1, **mx −4** (full-bleed —
/// cancels the card's p-1 inset), my 4, `hairline(0.07)`.
public struct SupermuxZeronMenuSeparator: View {
    private let theme: SupermuxZeronTheme

    public init(theme: SupermuxZeronTheme) {
        self.theme = theme
    }

    public var body: some View {
        Rectangle()
            .fill(theme.hairline(0.07))
            .frame(height: 1)
            .padding(.horizontal, -4)
            .padding(.vertical, 4)
    }
}

// MARK: - Row

/// `menu_row` (`popover.rs:629–662`): px 8, py 6, r 8, gap 10, 13 pt.
///
/// The active row wears the full `cardSelectedBG()` and `theme.text`; an
/// inactive row rests at `text @ 0.9` and blends up to the same wash on hover
/// over 150 ms `EASE_TAILWIND`.
public struct SupermuxZeronMenuRow<Trailing: View>: View {
    private let theme: SupermuxZeronTheme
    private let label: String
    private let isActive: Bool
    private let action: () -> Void
    private let trailing: Trailing

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        theme: SupermuxZeronTheme,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.theme = theme
        self.label = label
        self.isActive = isActive
        self.action = action
        self.trailing = trailing()
    }

    private typealias M = SupermuxZeronMetrics.Pickers

    public var body: some View {
        Button(action: action) {
            HStack(spacing: M.menuRowGap) {
                Text(label)
                    .font(SupermuxZeronFonts.sans(size: M.menuRowTextSize))
                    .foregroundStyle(isActive || isHovered ? theme.text : theme.text.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, M.menuRowPadX)
            .padding(.vertical, M.menuRowPadY)
            .background(
                RoundedRectangle(cornerRadius: M.menuRowRadius, style: .continuous)
                    // The wash rests at zero OPACITY over a fixed color, never
                    // at `Color.clear` — a mid-fade through clear flashes grey.
                    .fill(theme.cardSelectedBG())
                    .opacity(isActive || isHovered ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
                        value: isHovered
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: M.menuRowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

// MARK: - Default badge

/// `default_badge` (`pickers.rs:3147–3154`): a **ghost** badge — bare text, no
/// border, no fill. 10 pt SEMIBOLD, `textMuted @ 0.6`. The source comment is
/// explicit that t3code draws an outline pill here and zeron deliberately does
/// not.
public struct SupermuxZeronDefaultBadge: View {
    private let theme: SupermuxZeronTheme
    private let label: String

    public init(theme: SupermuxZeronTheme, label: String? = nil) {
        self.theme = theme
        self.label = label ?? String(
            localized: "supermux.zeron.menu.defaultBadge",
            defaultValue: "Default",
            bundle: .supermuxZeronUI
        )
    }

    public var body: some View {
        Text(label)
            .font(SupermuxZeronFonts.sans(size: 10, weight: .semibold))
            .foregroundStyle(theme.textMuted.opacity(0.6))
    }
}

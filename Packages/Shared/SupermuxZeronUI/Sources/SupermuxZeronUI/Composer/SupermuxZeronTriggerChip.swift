//
//  SupermuxZeronTriggerChip.swift
//  SupermuxZeronUI
//
//  The ghost pill shared by the model chip, the effort chip, and (at 20 pt) the
//  footer row. Spec 04 §4.2 / §6.2, from `pickers.rs:1983-2148`.
//
//  Comment citation: zeron composer/styles.tsx `pill`: `h-8 rounded-lg px-2.5
//  gap-1.5 text-[12px] font-medium text-muted-foreground`, icons size-4,
//  hover/open wash — **no border, no caret**. The actions row stays quiet.
//
//  ── The label color is a BLEND, not a swap ──
//
//  rest  = set ? theme.text @ 0.9 : theme.textMuted
//  hover = theme.text
//  over 150 ms `cubic-bezier(0.4, 0, 0.2, 1)`.
//  The model chip always passes `set = true`; the effort chip passes
//  `set = customized`, so it rests muted until something departs from default.
//

public import SwiftUI

// MARK: - Trigger chip

/// The 32 pt actions-row chip.
///
/// Deliberately takes plain values and two closures rather than a store: it is
/// rendered inside the actions row, which may sit under a lazy boundary in a
/// mount, and a view holding an observable reference there is the cmux #2586
/// spin loop.
public struct SupermuxZeronTriggerChip: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    private let theme: SupermuxZeronTheme
    private let label: String
    private let icon: SupermuxZeronComposerIcon.Name?
    private let iconTint: Color?
    private let suffix: String?
    private let suffixTint: Color?
    private let isSet: Bool
    private let isOpen: Bool
    private let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - isSet: Whether the chip carries a chosen value. The model chip is
    ///     always `true`; the effort chip is `true` only when customized.
    ///   - isOpen: Whether this chip's popover is showing — it holds the full
    ///     `elementHover` wash while open.
    ///   - suffix: The optional muted trailing run (`text_muted @ 0.7`). The
    ///     composer's own two chips pass `nil`; the effort value is its OWN
    ///     chip's label, not a suffix.
    public init(
        theme: SupermuxZeronTheme,
        label: String,
        icon: SupermuxZeronComposerIcon.Name? = nil,
        iconTint: Color? = nil,
        suffix: String? = nil,
        suffixTint: Color? = nil,
        isSet: Bool,
        isOpen: Bool = false,
        action: @escaping () -> Void
    ) {
        self.theme = theme
        self.label = label
        self.icon = icon
        self.iconTint = iconTint
        self.suffix = suffix
        self.suffixTint = suffixTint
        self.isSet = isSet
        self.isOpen = isOpen
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.chipGap) {
                if let icon {
                    SupermuxZeronComposerIcon(icon, size: Metrics.chipIcon)
                        .foregroundStyle(iconTint ?? theme.textMuted)
                }
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(labelColor)
                if let suffix {
                    Text(suffix)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(suffixTint ?? theme.textMuted.opacity(0.7))
                }
            }
            .font(
                SupermuxZeronFonts.sans(
                    size: SupermuxZeronComposerFlip.chipTextSize,
                    weight: .medium
                )
            )
            .padding(.horizontal, Metrics.chipPadX)
            .frame(height: Metrics.triggerChipHeight)
            // gpui `max_w(208)` is a CAP over a content-sized box; SwiftUI's
            // `.frame(maxWidth:)` instead accepts whatever the parent offers, so
            // without the `fixedSize` both chips inflate to a 208 pt slab and
            // the cluster stops hugging its text (screenshot: "Fable 5" is ~63
            // pt wide). `fixedSize` after the cap restores "hug, then truncate
            // at 208".
            .frame(maxWidth: SupermuxZeronComposerFlip.chipMaxWidth)
            .fixedSize(horizontal: true, vertical: false)
            // No border, no caret glyph — just the wash.
            .background(wash)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// `text_color(hover_blend(id, rest, theme.text))` — the label follows
    /// HOVER only. `open` drives the background, never the label
    /// (`pickers.rs:2022-2036`): a chip whose popover is open but whose pointer
    /// has moved away decays to its resting tone.
    private var labelColor: Color {
        if isHovered { return theme.text }
        return isSet ? theme.text.opacity(0.9) : theme.textMuted
    }

    /// The wash never rests at `Color.clear` — it rests at `elementHover` with
    /// zero opacity, so the mid-fade cannot pass through grey. Animating the
    /// OPACITY of a fixed color is the faithful equivalent of zeron's
    /// premultiplied-sRGB `hover_blend`.
    private var wash: some View {
        RoundedRectangle(cornerRadius: Metrics.chipRadius, style: .continuous)
            .fill(theme.elementHover)
            .opacity(isOpen || isHovered ? 1 : 0)
            .animation(
                reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
                value: isHovered
            )
            // `bg(open ? element_hover : hover_blend(...))` — opening SNAPS the
            // full wash on (the open branch is not a blend), so `isOpen` must be
            // excluded from the animated value or the popover's own appearance
            // drags a 150 ms fade behind it.
            .animation(nil, value: isOpen)
    }
}

// MARK: - Footer row

/// The row under the pill: "Local checkout" on the left, the ref on the right.
///
/// **Returns nothing unless the resolved project has git** (`space.git_detected`)
/// — the whole row is absent, not empty.
///
/// Two states, and they never mix: an existing session shows read-only
/// `footer_label`s (no chevron on either side); a new-session draft shows
/// interactive `footer_chip`s (a chevron on both). `docs/screenshot.png` shows
/// one of each, which no branch in the source produces — a known upstream
/// mismatch (spec 04 §11.2). The code is the spec.
public struct SupermuxZeronComposerFooter: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    /// One side of the row.
    public struct Item: Sendable, Equatable, Hashable {
        public let icon: SupermuxZeronComposerIcon.Name
        public let label: String

        public init(icon: SupermuxZeronComposerIcon.Name, label: String) {
            self.icon = icon
            self.label = label
        }
    }

    /// Read-only labels vs. interactive chips.
    public enum Mode: Sendable, Equatable, Hashable {
        /// An existing session: labels, no chevrons, `textMuted @ 0.6`.
        case labels
        /// A new-session draft: chips with a trailing `altArrowDown`.
        case chips
    }

    private let theme: SupermuxZeronTheme
    private let leading: Item
    private let trailing: Item
    private let mode: Mode
    private let onTapLeading: () -> Void
    private let onTapTrailing: () -> Void

    public init(
        theme: SupermuxZeronTheme,
        leading: Item,
        trailing: Item,
        mode: Mode = .labels,
        onTapLeading: @escaping () -> Void = {},
        onTapTrailing: @escaping () -> Void = {}
    ) {
        self.theme = theme
        self.leading = leading
        self.trailing = trailing
        self.mode = mode
        self.onTapLeading = onTapLeading
        self.onTapTrailing = onTapTrailing
    }

    public var body: some View {
        HStack(spacing: SupermuxZeronMetrics.Theme.spaceSM) {
            item(leading, action: onTapLeading)
            Spacer(minLength: 0)
            item(trailing, action: onTapTrailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        // The container's 8 pt gap sits above the row; bleeding 8 of its 16 pt
        // bottom padding leaves 8 below — equal air on both sides.
        .padding(.bottom, -SupermuxZeronMetrics.Theme.spaceSM)
    }

    @ViewBuilder
    private func item(_ item: Item, action: @escaping () -> Void) -> some View {
        switch mode {
        case .labels:
            SupermuxZeronFooterLabel(theme: theme, item: item)
        case .chips:
            SupermuxZeronFooterChip(theme: theme, item: item, action: action)
        }
    }
}

/// `footer_label` — 20 pt, max 160, no chevron, everything at
/// `textMuted @ 0.6`.
struct SupermuxZeronFooterLabel: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    let theme: SupermuxZeronTheme
    let item: SupermuxZeronComposerFooter.Item

    var body: some View {
        HStack(spacing: Metrics.footerGap) {
            SupermuxZeronComposerIcon(item.icon, size: Metrics.footerTextSize)
                .foregroundStyle(theme.textMuted.opacity(0.6))
            Text(item.label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(SupermuxZeronFonts.sans(size: Metrics.footerTextSize, weight: .medium))
        .foregroundStyle(theme.textMuted.opacity(0.6))
        .padding(.horizontal, Metrics.footerPadX)
        .frame(height: Metrics.footerRowHeight)
        .frame(maxWidth: 160, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// `footer_chip` — 20 pt, max 280, radius 6, WITH the trailing chevron. The
/// label blends `textMuted @ 0.7` → `text @ 0.8` on hover; the icon sits at
/// `textMuted @ 0.7` and the chevron a step fainter at `@ 0.5`.
struct SupermuxZeronFooterChip: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    let theme: SupermuxZeronTheme
    let item: SupermuxZeronComposerFooter.Item
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.footerGap) {
                SupermuxZeronComposerIcon(item.icon, size: Metrics.footerTextSize)
                    .foregroundStyle(theme.textMuted.opacity(0.7))
                Text(item.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(
                        isHovered ? theme.text.opacity(0.8) : theme.textMuted.opacity(0.7)
                    )
                SupermuxZeronComposerIcon(.altArrowDown, size: Metrics.footerTextSize)
                    .foregroundStyle(theme.textMuted.opacity(0.5))
            }
            .font(SupermuxZeronFonts.sans(size: Metrics.footerTextSize, weight: .medium))
            .padding(.horizontal, Metrics.footerPadX)
            .frame(height: Metrics.footerRowHeight)
            .frame(maxWidth: 280, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.elementHover)
                    .opacity(isHovered ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
                        value: isHovered
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

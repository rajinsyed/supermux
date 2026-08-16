//
//  SupermuxZeronComposerPill.swift
//  SupermuxZeronUI
//
//  The composer pill chrome and the compact↔expanded morph. Spec 04 §1.4–§1.7,
//  from `composer.rs:5470-5600`.
//
//  ── The three things this file exists to get right ──
//
//  1. **The pill's bottom edge is stationary on screen.** The composer sits at
//     the bottom of the shell column, so growth moves the TOP edge. Expanded
//     pins the actions row to the bottom in an overlay; compact bottom-justifies
//     the 47 pt row. Anchoring the inner content to the top instead makes the
//     whole control cluster ride the animating height (zeron shipped that once).
//  2. **No drop shadow on glass.** A shadow paints BEHIND the translucent fill
//     and shows through as an inner glow. `shadow_lg` only when `!isGlass`.
//  3. **The controls never fade across the morph** — full alpha throughout. A
//     fade on the picker chips "read as flicker"; their screen position is
//     near-stationary across the flip, so nothing needs hiding.
//

public import SwiftUI

internal import Foundation

// MARK: - The pill

/// The composer pill: strip + input + actions row inside the 26 pt chrome.
///
/// Layout only — it neither owns the text nor decides the mode. The mount hands
/// it a committed `expanded`, an already-morphed `height`, and the eased
/// `morphProgress`, all of which come from ``SupermuxZeronComposerFlip``.
public struct SupermuxZeronComposerPill<Input: View, Actions: View, Strip: View>: View {
    public typealias Flip = SupermuxZeronComposerFlip
    private typealias Metrics = SupermuxZeronMetrics.Composer

    private let theme: SupermuxZeronTheme
    private let expanded: Bool
    private let height: CGFloat
    private let baseHeight: CGFloat
    private let morphProgress: Double
    private let morphFromHeight: CGFloat?
    private let input: Input
    private let actions: Actions
    private let strip: Strip

    /// - Parameters:
    ///   - expanded: The committed mode, already OR-ed with the forced-expanded
    ///     new-chat case.
    ///   - height: The pill's committed height — the morph's live value, or the
    ///     target at rest.
    ///   - baseHeight: The mode's target height WITHOUT the attachment strip;
    ///     the text box measures from this, not from the animating `height`, so
    ///     the committed layout never reflows mid-tween and the caret cannot
    ///     jump.
    ///   - morphProgress: Eased 0…1. `1` at rest.
    ///   - morphFromHeight: The morph's start height, needed only by the
    ///     collapse text glide. `nil` when no morph is in flight.
    public init(
        theme: SupermuxZeronTheme,
        expanded: Bool,
        height: CGFloat,
        baseHeight: CGFloat,
        morphProgress: Double = 1,
        morphFromHeight: CGFloat? = nil,
        @ViewBuilder input: () -> Input,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder strip: () -> Strip = { EmptyView() }
    ) {
        self.theme = theme
        self.expanded = expanded
        self.height = height
        self.baseHeight = baseHeight
        self.morphProgress = morphProgress
        self.morphFromHeight = morphFromHeight
        self.input = input()
        self.actions = actions()
        self.strip = strip()
    }

    public var body: some View {
        body(expanded: expanded)
            .frame(height: height, alignment: .bottom)
            .frame(maxWidth: .infinity)
            .background(
                SupermuxZeronComposerBackdrop(
                    theme: theme,
                    surface: .pill,
                    cornerRadius: Metrics.pillRadius
                )
            )
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.border, lineWidth: 1))
            .modifier(SupermuxZeronOpaqueShadow(isGlass: theme.isGlass))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.pillRadius, style: .continuous)
    }

    @ViewBuilder
    private func body(expanded: Bool) -> some View {
        if expanded {
            expandedBody
        } else {
            compactBody
        }
    }

    // MARK: Expanded (composer.rs:5498-5543)

    /// Textarea on top (`px-4 pb-1 pt-4`), actions row ABSOLUTE at the pill's
    /// stationary bottom — constant screen-y through the morph, with the 2.5 pt
    /// centering delta gliding out.
    private var expandedBody: some View {
        VStack(spacing: 0) {
            strip
            input
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .padding(.horizontal, Metrics.textBoxPadX)
                .padding(.top, Flip.textTopPad(morph: morphProgress))
                .padding(.bottom, Metrics.textBoxPadBottom)
                // The 76…260 clamp is the textarea's BORDER box — "content +
                // `pt-4 pb-1`" — which is why 76 + 46 + 2 = 124. gpui's `.h()`
                // is border-box, SwiftUI's `.frame(height:)` is content-box, so
                // the height MUST be applied after the padding; applied before
                // it, the box measures 96 and the empty expanded pill overflows
                // its own 124 pt by exactly the 20 pt of `TEXTAREA_PAD_V`.
                .frame(
                    height: Flip.textBoxHeight(expandedBaseHeight: baseHeight),
                    alignment: .top
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            HStack(spacing: Flip.clusterGap) {
                actions
            }
            // gpui's `.h(46)` is the BORDER box: `pt-1` and `pb-2.5` sit INSIDE
            // it (4 + 32 + 10 = 46). SwiftUI's `.frame(height:)` sizes the
            // content box, so the height must be applied AFTER the padding or
            // the row measures 60 and lifts the whole cluster 7 pt off the
            // pill's bottom edge.
            .padding(.leading, Flip.actionsPadLeading)
            .padding(.trailing, Flip.clusterInset(expanded: true, morph: morphProgress))
            .padding(.top, Flip.actionsPadTop)
            .padding(.bottom, Flip.actionsPadBottom)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: Metrics.actionsRowHeight)
            // The whole cluster glides the 2.5 pt centering delta; it never
            // fades, and it never rides the animating height.
            .offset(y: Flip.clusterOffsetY(expanded: true, morph: morphProgress))
        }
    }

    // MARK: Compact (composer.rs:5544-5598)

    /// Input and the actions cluster on one 47 pt line. The row is
    /// BOTTOM-justified: during the collapse morph the pill's top sweeps down
    /// over a stationary row and the text walks down via a decaying offset.
    private var compactBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            strip
            HStack(spacing: 0) {
                input
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Flip.compactTextPadLeading)
                    .padding(.trailing, Flip.compactTextPadTrailing)
                    .offset(y: -textGlide)
                HStack(spacing: Flip.clusterGap) {
                    actions
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, Flip.compactClusterPadLeading)
                .padding(.trailing, Flip.clusterInset(expanded: false, morph: morphProgress))
                .offset(y: Flip.clusterOffsetY(expanded: false, morph: morphProgress))
            }
            .frame(height: Flip.compactRowHeight)
        }
    }

    private var textGlide: CGFloat {
        guard let morphFromHeight else { return 0 }
        return Flip.collapseTextGlide(from: morphFromHeight, morph: morphProgress)
    }
}

// MARK: - Backdrop

/// The frosted plate under a composer surface.
///
/// zeron blurs the pill at **16** and menus at **44**. Neither
/// `NSVisualEffectView` nor SwiftUI's materials expose a sigma, so the port
/// preserves the RELATIVE difference (`.ultraThinMaterial` under the pill,
/// `.regularMaterial` under menus) and keeps the precisely-specified half — the
/// tints painted on top — exact (plan R3).
struct SupermuxZeronComposerBackdrop: View {
    enum Surface: Sendable, Equatable, Hashable {
        /// The composer pill: `inputGlassBG()` over a light blur.
        case pill
        /// A floating menu card: `glassOverlay()` over a heavy blur.
        case menu
    }

    let theme: SupermuxZeronTheme
    let surface: Surface
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if theme.isGlass {
                shape.fill(material)
            } else {
                // No behind-window blur exists on iOS; a floating card still
                // blurs APP content, which is the right effect there (§0.3 C13).
                switch surface {
                case .pill: shape.fill(.ultraThinMaterial)
                case .menu: shape.fill(.regularMaterial)
                }
            }
            shape.fill(tint)
        }
    }

    private var material: Material {
        switch surface {
        case .pill: .ultraThinMaterial
        case .menu: .regularMaterial
        }
    }

    private var tint: Color {
        switch surface {
        case .pill: theme.inputGlassBG()
        case .menu: theme.isGlass ? theme.glassOverlay() : theme.surfaceOverlay
        }
    }
}

/// Tailwind's `shadow-lg`, applied ONLY on an opaque platform.
///
/// gpui's own shadow geometry is unvendored (plan R13), so this is the Tailwind
/// recipe: `(0, 10, 15, −3) @ 0.1` + `(0, 4, 6, −4) @ 0.1`. CSS blur radius
/// halves into SwiftUI's; the negative spread has no SwiftUI analogue and is
/// dropped. Flagged as approximate.
struct SupermuxZeronOpaqueShadow: ViewModifier {
    let isGlass: Bool

    func body(content: Content) -> some View {
        if isGlass {
            content
        } else {
            content
                .shadow(color: .black.opacity(0.1), radius: 7.5, x: 0, y: 10)
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 4)
        }
    }
}

// MARK: - Icons

/// The composer's slice of the vendored Solar Linear set.
///
/// A local, composer-scoped accessor over `Icons.xcassets`: the shared
/// `SupermuxZeronIcon` inventory is another workstream's file, and the composer
/// must not block on it. Assets are template-rendered, so `.foregroundStyle`
/// tints them exactly as gpui's `text_color` does — **do not** substitute SF
/// Symbols (Solar's normalized 0.0625 em stroke is lighter and its corner
/// treatment is a distinctive superellipse).
public struct SupermuxZeronComposerIcon: View {
    /// lint:allow namespace-type — a real `View` value; `Name` below is its asset table.
    public enum Name: String, Sendable, Equatable, Hashable, CaseIterable {
        case command
        case arrowUp = "arrow-up"
        case paperclip
        case closeCircle = "close-circle"
        case dangerTriangle = "danger-triangle"
        case folder
        case folderWithFiles = "folder-with-files"
        case gitBranch = "git-branch"
        case altArrowDown = "alt-arrow-down"
        case magnifer
    }

    public let name: Name
    public let size: CGFloat

    public init(_ name: Name, size: CGFloat) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Image(name.rawValue, bundle: .supermuxZeronUI)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

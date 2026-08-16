//
//  SupermuxZeronToolChip.swift
//  SupermuxZeronUI
//
//  One tool chip: the 38 pt row (guide-rail segment + 30 pt card) and the card
//  itself — icon tile, verb, subject, chevron tile, and the expanded bodies.
//  Spec 03 §2–§4.
//
//  ── The card is 30 pt INCLUDING its border (§0.3 C9) ──
//
//  zeron's shipped screenshots paint an expandable card at 32 px (1 border + 30
//  interior + 1 border) while the plain card paints 30, and the source comments
//  on the consequence: with N chips the group overflowed its analytic height by
//  2N px and the last chips rendered clipped ("tool calls cut off at the
//  bottom"). The plan resolves this to **30 pt including the 1 pt border**, which
//  is what `strokeBorder` on a `.frame(height: 30)` view gives — it strokes
//  INWARD. Each row is then exactly 38 and `2 + 38N` is exact.
//
//  ── The rail is per-row, not per-group ──
//
//  Each row paints its own 1 pt segment spanning the row's full height, and
//  `CHIP_GAP` is literally 0, so the segments abut and read as one unbroken
//  spine. There are no connector stubs, elbows or caps anywhere.
//
//  ── One card, not a floating panel ──
//
//  An expandable chip is ONE card whose header row IS the chip and whose body
//  is the detail — never a second card below it. The rail stretches with the
//  card, detail included, so an open detail cannot break the spine.
//

public import CoreGraphics
public import Foundation
public import SwiftUI

public import SupermuxClaudeHarness

// MARK: - The chip row

/// One chip row: the guide-rail segment plus the card, at the analytic height.
///
/// Holds only VALUES and closures — never the fold store — so it is safe below
/// a `LazyVStack` boundary (cmux #2586).
public struct SupermuxZeronToolChip: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    private let tool: SupermuxHarnessToolCall
    private let content: SupermuxZeronChipContent
    private let isOpen: Bool
    private let fold: SupermuxZeronFold
    /// The group's single per-pass timestamp, so the group tween and every card
    /// tween resolve the 400 ms window against the SAME instant.
    private let now: Date
    /// Threaded down from the group rather than read here, so the group's tween
    /// and the card's take the SAME decision on the same pass.
    private let reduceMotion: Bool
    private let theme: SupermuxZeronTheme
    private let highlights: SupermuxZeronDiffHighlights?
    private let onToggle: () -> Void
    private let onFetchBlob: () -> Void

    public init(
        tool: SupermuxHarnessToolCall,
        content: SupermuxZeronChipContent,
        isOpen: Bool,
        fold: SupermuxZeronFold,
        now: Date = Date(),
        reduceMotion: Bool = false,
        theme: SupermuxZeronTheme,
        highlights: SupermuxZeronDiffHighlights? = nil,
        onToggle: @escaping () -> Void = {},
        onFetchBlob: @escaping () -> Void = {}
    ) {
        self.tool = tool
        self.content = content
        self.isOpen = isOpen
        self.fold = fold
        self.now = now
        self.reduceMotion = reduceMotion
        self.theme = theme
        self.highlights = highlights
        self.onToggle = onToggle
        self.onFetchBlob = onFetchBlob
    }

    /// The row's analytic height: the card plus 4 pt of visible rail above and
    /// below. A closed row is exactly `CHIP_HEIGHT` = 38.
    public static func rowHeight(content: SupermuxZeronChipContent, isOpen: Bool) -> CGFloat {
        content.cardHeight(isOpen: isOpen) + (Chips.rowHeight - Chips.cardHeight)
    }

    public var body: some View {
        let target = content.cardHeight(isOpen: isOpen)
        // `now` is the group's ONE timestamp for the pass: the mount decision
        // and the animation decision must agree, and two `Date()` calls can
        // straddle the 400 ms boundary.
        //
        // A PURE read of wall-clock — no state is written, so this is legal
        // inside `body` under the list-boundary rule, and a row that scrolls
        // back into view past the window renders statically.
        let animation = reduceMotion ? nil : fold.animation(now: now)

        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(theme.ink(0.08))
                .frame(width: Chips.railWidth)
                .frame(maxHeight: .infinity)

            card(now: now)
                .frame(height: target, alignment: .top)
                // The rounded clip does the bounds clip too, which is what
                // shears the detail body off during a close tween.
                .clipShape(RoundedRectangle(cornerRadius: Chips.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Chips.cardRadius, style: .continuous)
                        .strokeBorder(theme.hairline(0.07), lineWidth: 1)
                )
                // The tap target rides OUTSIDE the card's clip. An overlay
                // inside it would be sheared away, so a padded hit area there
                // silently does nothing — the touch target must be a sibling
                // of the clip, not a child of it.
                .overlay(alignment: .top) { tapTarget }
                .padding(.vertical, (Chips.rowHeight - Chips.cardHeight) / 2)
                .padding(.leading, Chips.railInset)
        }
        .padding(.leading, Chips.railInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight(content: content, isOpen: isOpen), alignment: .top)
        .animation(animation, value: target)
    }

    /// On touch the target grows into the 4 pt rail bands above and below the
    /// header; `(38 − 30) / 2`. macOS keeps the painted 30.
    private static var tapOutset: CGFloat {
        #if os(macOS)
        return 0
        #else
        return (Chips.rowHeight - Chips.cardHeight) / 2
        #endif
    }

    /// The chip header's tap area, painted nowhere.
    ///
    /// Covers the 30 pt header row plus, on touch, the rail bands around it —
    /// a 38 pt target without moving a single painted pixel (plan §4). The
    /// `.offset` re-centres the outset padding on the header, so the target
    /// hangs 4 pt ABOVE the card rather than reaching 8 pt down into an open
    /// detail body: tapping an expanded chip's output must not collapse it.
    @ViewBuilder
    private var tapTarget: some View {
        if content.isExpandable {
            let outset = Self.tapOutset
            Color.clear
                .frame(height: Chips.cardHeight)
                .padding(.vertical, outset)
                .contentShape(Rectangle())
                .offset(y: -outset)
                .onTapGesture(perform: onToggle)
                .modifier(SupermuxZeronPointerCursor())
                .accessibilityHidden(true)
        }
    }

    // MARK: The card

    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // The body stays MOUNTED while a close tween shrinks over it —
            // unmounting it would collapse the card instantly and the tween
            // would animate over nothing.
            if isOpen || fold.isArmed(now: now) {
                if let invocation = content.invocation {
                    SupermuxZeronChipSeparator(theme: theme)
                    SupermuxZeronChipDetail(detail: invocation, theme: theme)
                        .frame(height: SupermuxZeronChipDetail.bodyHeight(of: invocation), alignment: .top)
                }
                if let detail = content.detail {
                    SupermuxZeronChipSeparator(theme: theme)
                    SupermuxZeronChipDetail(detail: detail, theme: theme, highlights: highlights)
                        .frame(height: SupermuxZeronChipDetail.bodyHeight(of: detail), alignment: .top)
                }
                if let affordance = content.affordance {
                    // No hairline above the affordance — it sits directly under
                    // whichever body came last.
                    SupermuxZeronBlobAffordanceRow(
                        affordance: affordance,
                        theme: theme,
                        onTap: onFetchBlob
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.ink(0.03))
    }

    // MARK: The header row (== the chip)

    private var header: some View {
        // The tap gesture lives on `tapTarget`, outside the card's clip; this
        // is paint only.
        SupermuxZeronChipHeaderRow(
            tool: tool,
            theme: theme,
            chevron: content.isExpandable ? isOpen : nil,
            onActivate: content.isExpandable ? onToggle : nil
        )
    }
}

// MARK: - The chip's content row

/// Icon tile, verb, subject and (when the chip expands) the chevron tile.
///
/// Shared by the plain chip and the header of an expandable card, which is what
/// makes the two paths pixel-identical.
struct SupermuxZeronChipHeaderRow: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    let tool: SupermuxHarnessToolCall
    let theme: SupermuxZeronTheme
    /// `nil` on a chip that cannot expand — the tile is absent, not disabled.
    let chevron: Bool?
    /// Activation for assistive tech. The painted tap target is an overlay
    /// OUTSIDE the card's clip and is `accessibilityHidden`, so without an
    /// action here an expandable chip would be readable by VoiceOver and not
    /// openable by it.
    var onActivate: (() -> Void)?

    /// The failed tint. Note what does NOT change: the icon glyph stays
    /// `textMuted`, and the card's fill, border and tiles are untouched. There
    /// is no red wash and no red border.
    private var isError: Bool { tool.status == .failed }

    var body: some View {
        // 8 pt between EVERY element: icon↔verb, verb↔subject, subject↔chevron.
        HStack(spacing: SupermuxZeronMetrics.Theme.spaceSM) {
            SupermuxZeronChipTile(fill: theme.ink(0.08)) {
                // The glyph stays `textMuted` on a FAILED chip — only the verb
                // and subject go red. There is no red wash and no red border.
                SupermuxZeronIcon(tool.chipKind.icon, size: Chips.tileIconGlyph)
                    .foregroundStyle(theme.textMuted)
            }

            Text(tool.verb)
                .font(SupermuxZeronFonts.sans(size: Chips.textSize, weight: .medium))
                .foregroundStyle(isError ? theme.danger : theme.textMuted)
                .lineLimit(1)
                .fixedSize()

            Text(tool.chipSubject)
                .font(SupermuxZeronFonts.sans(size: Chips.textSize))
                .foregroundStyle(isError ? theme.danger : theme.text.opacity(Chips.subjectAlpha))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let chevron {
                SupermuxZeronChipTile(fill: theme.ink(0.06)) {
                    // SWAPPED, never rotated: there is no chevron rotation
                    // anywhere on a tool chip in zeron.
                    Text(verbatim: chevron ? "\u{25BE}" : "\u{25B8}")
                        .font(SupermuxZeronFonts.sans(size: Chips.tileChevronGlyph))
                        .foregroundStyle(theme.textMuted.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, SupermuxZeronMetrics.Theme.spaceSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Chips.cardHeight)
        .accessibilityElement(children: .combine)
        // The humanizer's sentence ("Ran command") is the ACCESSIBLE label; the
        // visible verb is one word because the chip has 8 pt of room.
        .accessibilityLabel(
            Text(tool.status == .running ? tool.labels.running : tool.labels.done)
        )
        .accessibilityValue(Text(tool.chipSubject))
        .modifier(SupermuxZeronChipActivation(onActivate: onActivate))
    }
}

/// The button trait plus the activation action, or neither.
///
/// A chip with no bodies is inert in zeron — no pointer, no click — so it must
/// not claim the trait either.
private struct SupermuxZeronChipActivation: ViewModifier {
    let onActivate: (() -> Void)?

    func body(content: Content) -> some View {
        if let onActivate {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onActivate)
        } else {
            content
        }
    }
}

// MARK: - Tiles

/// An 18 × 18 pt rounded tile — the icon tile, the chevron tile, and the group
/// header's disclosure tile are all this shape.
struct SupermuxZeronChipTile<Content: View>: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    let fill: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: Chips.tileSize, height: Chips.tileSize)
            .background(
                RoundedRectangle(cornerRadius: Chips.tileRadius, style: .continuous)
                    .fill(fill)
            )
    }
}

// MARK: - Icons

public extension SupermuxHarnessToolCall.ChipKind {
    /// The Solar Icons glyph each chip kind renders (spec 03 §3.4).
    ///
    /// Three pairs deliberately SHARE a glyph: Read and Patch both use
    /// `document`, Fetch and Web both use `global`, MCP and Tool both use
    /// `widget`. That is zeron's own table, not an oversight.
    ///
    /// Do NOT substitute SF Symbols — Solar Linear's normalized 0.0625 em
    /// stroke is lighter than SF's `.regular`, and `document-add` and
    /// `folder-with-files` have no acceptable SF equivalent at all.
    var icon: SupermuxZeronIcon.Name {
        switch self {
        case .exec: .command
        case .readFile, .applyPatch: .document
        case .writeFile: .documentAdd
        case .editFile: .pen
        case .search: .magnifer
        case .glob: .folderWithFiles
        case .webFetch, .webSearch: .global
        case .todo: .checklist
        case .mcp, .unknown: .widget
        }
    }
}

// MARK: - Hit target

/// Makes a 26 / 30 pt header row tappable without moving a painted pixel.
///
/// Both header primitives (the group header and the thinking row) are shorter
/// than the 44 pt HIG minimum. Plan §4's rule is that painted geometry never
/// changes for touch, so the row keeps its exact height and the TOUCH area
/// grows underneath it.
///
/// **The expansion must not be clipped.** An expanded chip card clips its own
/// bounds, so a padded overlay placed inside one is sheared away and the target
/// silently stays at its painted size — which is why `SupermuxZeronToolChip`
/// hangs its own target outside the clip instead of using this modifier.
public struct SupermuxZeronChipTapTarget: ViewModifier {
    private let isEnabled: Bool
    private let onTap: () -> Void

    public init(isEnabled: Bool = true, onTap: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onTap = onTap
    }

    public func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                #if !os(macOS)
                // 26 + 2×9 = 44 exactly.
                .overlay {
                    Color.clear
                        .padding(.vertical, -9)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTap)
                }
                #else
                .onTapGesture(perform: onTap)
                .modifier(SupermuxZeronPointerCursor())
                #endif
        } else {
            content
        }
    }
}

// MARK: - Pointer

/// `cursor_pointer()` where the platform offers it.
///
/// `.pointerStyle` is macOS 15+; this package targets macOS 14, so a 14 host
/// simply keeps the arrow. The affordance is the chevron tile, not the cursor.
struct SupermuxZeronPointerCursor: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

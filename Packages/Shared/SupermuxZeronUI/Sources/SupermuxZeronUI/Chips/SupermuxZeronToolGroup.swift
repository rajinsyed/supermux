//
//  SupermuxZeronToolGroup.swift
//  SupermuxZeronUI
//
//  The tool-group row: a 26 pt header (disclosure tile + summary line) over a
//  clipped fold body of railed chips. Spec 03 §1, §2, §6, §8.
//
//  ── Geometry, top to bottom ──
//
//      26 pt   header:  px 4 · gap 8 · [18 pt tile] [12 pt summary]
//      2 pt    CHIPS_TOP_PAD
//      38 pt   chip row  ×N   (each: 1 pt rail at x=12, 30 pt card at x=25)
//
//  The rail is inset 12 from the content column's left edge, which is exactly
//  what centers it under the header tile: the tile spans [4, 22] so its centre
//  is 13, and the 1 pt rail spans [12, 13] so its centre is 12.5.
//
//  ── Why the header is never red ──
//
//  Even when children failed. zeron's comment: agents routinely have failed
//  probes mid-work, and a red HEADER read as "this whole step broke" (user
//  report). Failures show on the individual chips (danger tint on verb and
//  subject) and in the summary's trailing "· N failed" count.
//
//  ── The coupled tween (§6.3) ──
//
//  Tapping a CHIP does two things: it flips that chip's own fold, AND it arms
//  the group body's height tween without changing the group's open state. The
//  group's `openHeight` is analytic over the final detail state, so without the
//  arm the row would snap to the new height while the card was still mid-tween
//  — content below teleported on expand and the shrinking card clipped on
//  collapse. Both tweens share the tap instant and the RESIZE curve, so the row
//  tracks the card's bottom edge frame-for-frame.
//

public import CoreGraphics
public import Foundation
public import SwiftUI

public import SupermuxClaudeHarness

// MARK: - The group row

/// One `SupermuxHarnessRow.Kind.toolGroup`, rendered whole.
///
/// A lone tool call is a group of ONE — that uniformity is what lets the rail,
/// the summary and the `2 + 38N` height model share one implementation.
///
/// **Holds no store.** Fold state arrives as a plain ``SupermuxZeronToolGroupFolds``
/// value and every capability is a closure in ``SupermuxZeronFoldActions``, so
/// this view is safe below a `LazyVStack` boundary (cmux #2586).
///
/// `folds` and `actions` are defaulted so `SupermuxZeronRowView`'s existing
/// `(group:theme:)` call site keeps compiling; with the defaults the group
/// renders collapsed and inert, which is correct-but-static. The transcript host
/// must thread a real ``SupermuxZeronFoldStore`` snapshot through for the fold
/// to work — see the note in ``SupermuxZeronFoldStore``.
public struct SupermuxZeronToolGroupView: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    private let group: SupermuxHarnessToolGroup
    private let folds: SupermuxZeronToolGroupFolds
    private let theme: SupermuxZeronTheme
    private let actions: SupermuxZeronFoldActions
    private let highlights: [String: SupermuxZeronDiffHighlights]

    /// Every chip's bodies, resolved ONCE per render.
    ///
    /// `SupermuxHarnessToolCall.detail` re-parses `structuredPatch` and
    /// re-truncates the diff on each access; resolving it in `init` keeps that
    /// off the per-frame path and is also what makes `openHeight` cheap.
    private let contents: [SupermuxZeronChipContent]

    /// The tally line, resolved ONCE per render for the same reason.
    ///
    /// `SupermuxHarnessToolGroup.summary` re-tallies every tool and performs up
    /// to eight `String(localized:)` catalog lookups on each access; reading it
    /// straight from `body` redoes all of that on every frame of the fold tween.
    private let summary: String

    @State private var isHeaderHovered = false

    /// Reduce Motion. gpui honors `App::reduce_motion` inside every
    /// `with_animation` element automatically, so zeron's fold path never
    /// consults the flag and still SNAPS under the setting (spec 03 §6.1 is
    /// about the code path; spec 07 §6 lists "the RESIZE height tweens" among
    /// the oneshots that snap to their END state). SwiftUI has no such
    /// automatic honoring — the gate has to be explicit or the port animates
    /// where zeron does not.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        group: SupermuxHarnessToolGroup,
        folds: SupermuxZeronToolGroupFolds = SupermuxZeronToolGroupFolds(),
        theme: SupermuxZeronTheme,
        actions: SupermuxZeronFoldActions = .inert,
        highlights: [String: SupermuxZeronDiffHighlights] = [:]
    ) {
        self.group = group
        self.folds = folds
        self.theme = theme
        self.actions = actions
        self.highlights = highlights
        self.contents = group.tools.map { SupermuxZeronChipContent(tool: $0) }
        self.summary = group.summary
    }

    // MARK: Analytic heights

    /// Whether a chip's detail is currently open.
    private func isChipOpen(_ index: Int) -> Bool {
        Self.isChipOpen(contents, folds, index)
    }

    /// The fold body's height for a resolved state — the ONE height formula.
    ///
    /// `openHeight = chipsHeight(N) + Σ over OPEN chips of
    /// (invocation + detail + affordance)`; closed is 0. Both the instance
    /// `body` and the static ``rowHeight(group:folds:)`` route through here so
    /// a host that pre-sizes rows and the view that paints them can never
    /// disagree — the disagreement is a clipped last chip.
    static func bodyHeight(
        contents: [SupermuxZeronChipContent],
        folds: SupermuxZeronToolGroupFolds,
        autoOpen: Bool
    ) -> CGFloat {
        guard folds.group.isOpen(autoOpen: autoOpen), !contents.isEmpty else { return 0 }
        var height = Chips.chipsHeight(contents.count)
        for index in contents.indices where Self.isChipOpen(contents, folds, index) {
            height += contents[index].expandedExtraHeight
        }
        return height
    }

    /// A chip's detail is open only when it CAN open and its fold says so —
    /// detail folds have no auto-open rule; a chip opens on a tap alone.
    private static func isChipOpen(
        _ contents: [SupermuxZeronChipContent],
        _ folds: SupermuxZeronToolGroupFolds,
        _ index: Int
    ) -> Bool {
        contents.indices.contains(index)
            && contents[index].isExpandable
            && folds.detail(index).isOpen(autoOpen: false)
    }

    /// The group body's target height right now.
    private var bodyTarget: CGFloat {
        Self.bodyHeight(contents: contents, folds: folds, autoOpen: group.autoOpen)
    }

    /// The whole row's height, header included — spec 03 §8.
    public static func rowHeight(
        group: SupermuxHarnessToolGroup,
        folds: SupermuxZeronToolGroupFolds
    ) -> CGFloat {
        Chips.groupHeaderHeight
            + bodyHeight(
                contents: group.tools.map { SupermuxZeronChipContent(tool: $0) },
                folds: folds,
                autoOpen: group.autoOpen
            )
    }

    // MARK: Body

    public var body: some View {
        let isOpen = folds.group.isOpen(autoOpen: group.autoOpen)
        let target = bodyTarget
        // ONE timestamp for the pass, shared with every chip, so the group's
        // tween and each card's tween cannot land on opposite sides of the
        // 400 ms boundary mid-render — the coupled tween's whole point is that
        // both animate off the same instant.
        //
        // Pure wall-clock read — see SupermuxZeronFoldTween's header. Past the
        // window this is nil, so a `LazyVStack` remount cannot replay the fold
        // (plan R5).
        let now = Date()
        let animation = reduceMotion ? nil : folds.group.animation(now: now)

        VStack(alignment: .leading, spacing: 0) {
            header(isOpen: isOpen)
            chips(now: now, reduceMotion: reduceMotion)
                .frame(height: target, alignment: .top)
                .clipped()
                .animation(animation, value: target)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private func header(isOpen: Bool) -> some View {
        HStack(spacing: Chips.groupHeaderGap) {
            SupermuxZeronChipTile(fill: theme.ink(0.06)) {
                // Swapped, NOT rotated — there is no chevron rotation spec on
                // this path, and adding one is a visible divergence.
                Text(verbatim: isOpen ? "\u{25BE}" : "\u{25B8}")
                    .font(SupermuxZeronFonts.sans(size: Chips.tileChevronGlyph))
                    .foregroundStyle(theme.textMuted.opacity(0.7))
            }

            Text(summary)
                .font(SupermuxZeronFonts.sans(size: Chips.textSize))
                // Quiet even when children failed (see the file header).
                .foregroundStyle(isHeaderHovered ? theme.text : theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Chips.groupHeaderPadX)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The WHOLE 26 pt row is the toggle — tile and text alike.
        .frame(height: Chips.groupHeaderHeight)
        .contentShape(Rectangle())
        // Hover lifts the TEXT only; the tile's fill is static. `.onHover`
        // never fires on iOS, so the header simply rests at `textMuted` there.
        .onHover { isHeaderHovered = $0 }
        // Reduced motion snaps the fade to its endpoint (`origin = target`,
        // motion.rs:492) — it does not disable the hover state itself.
        .animation(
            reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
            value: isHeaderHovered
        )
        // Plan §4: the painted 26 pt row never changes; on touch the HIT area
        // grows underneath it to the 44 pt HIG minimum (26 + 2×9). The chips
        // container is a LATER sibling in this `VStack`, so where the two
        // targets overlap the chip's own wins — the header cannot steal a tap
        // meant for chip 1.
        .modifier(SupermuxZeronChipTapTarget(onTap: toggleGroup))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(summary))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Chips

    private func chips(now: Date, reduceMotion: Bool) -> some View {
        VStack(alignment: .leading, spacing: Chips.gap) {
            ForEach(Array(group.tools.enumerated()), id: \.element.id) { index, tool in
                SupermuxZeronToolChip(
                    tool: tool,
                    content: contents[index],
                    isOpen: isChipOpen(index),
                    fold: folds.detail(index),
                    now: now,
                    reduceMotion: reduceMotion,
                    theme: theme,
                    highlights: highlights[tool.id],
                    onToggle: { toggleDetail(index) },
                    onFetchBlob: { fetchBlob(index) }
                )
            }
        }
        .padding(.top, Chips.topPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Intents

    private func toggleGroup() {
        actions.toggleGroup(
            SupermuxZeronFoldToggle(
                key: group.id,
                // The tween starts at the height the body has RIGHT NOW.
                from: bodyTarget,
                autoOpen: group.autoOpen
            )
        )
    }

    /// Flip one chip's detail AND arm the group's tween from its pre-tap height
    /// (§6.3). The group's open state is untouched.
    private func toggleDetail(_ index: Int) {
        guard contents.indices.contains(index), contents[index].isExpandable else { return }
        let key = SupermuxZeronFoldStore.detailKey(rowID: group.id, index: index)
        actions.toggleDetail(
            SupermuxZeronFoldToggle(
                key: key,
                from: contents[index].cardHeight(isOpen: isChipOpen(index)),
                autoOpen: false
            ),
            SupermuxZeronFoldToggle(
                key: group.id,
                // `openHeight` is still the PRE-tap value here, which is
                // exactly the group tween's start.
                from: bodyTarget,
                autoOpen: group.autoOpen
            )
        )
    }

    private func fetchBlob(_ index: Int) {
        guard let affordance = contents[safe: index]?.affordance else { return }
        actions.fetchBlob(affordance)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

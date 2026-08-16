//
//  SupermuxZeronChipDetail.swift
//  SupermuxZeronUI
//
//  The three bodies an expanded tool chip can carry — Output, Stats, Diff —
//  plus the counted tail row and the "Show full output" blob affordance.
//  Spec 03 §4, plan §2.0.
//
//  ── Why every row is a FIXED 18 pt box with `.lineLimit(1)` ──
//
//  Plan R4. zeron's whole fold model is analytic (`1 + rows·18 + 12`), so a
//  tween interpolates two KNOWN heights and a virtualizer never measures an
//  offscreen row. SwiftUI measures instead — which would be fine until a font
//  substitution changed a line's rendered height, at which point the analytic
//  height and the content disagree and the row clips. The mitigation is
//  structural rather than defensive: a single-line box that cannot grow. Every
//  text row here is `.frame(height:)` + `.lineLimit(1)`, so the content
//  *cannot* exceed the box the fold reserved for it.
//
//  ── Separator ownership ──
//
//  `SupermuxHarnessChipDetail.height` counts the 1 pt hairline ABOVE the body
//  (zeron's `DETAIL_SEPARATOR + body`), but the hairline is a sibling emitted
//  by the card, not part of the body. ``SupermuxZeronChipDetail/bodyHeight``
//  is therefore `height − 1`, and ``SupermuxZeronChipSeparator`` is what the
//  card puts above it.
//

public import CoreGraphics
public import Foundation
public import SwiftUI

public import SupermuxClaudeHarness

// MARK: - The detail body

/// One expanded chip body: raw output, an edit tally, or a real diff.
///
/// Renders at exactly `detail.height − 1` (the card owns the hairline), so the
/// group's analytic fold height stays exact.
public struct SupermuxZeronChipDetail: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    private let detail: SupermuxHarnessChipDetail
    private let theme: SupermuxZeronTheme
    private let highlights: SupermuxZeronDiffHighlights?

    public init(
        detail: SupermuxHarnessChipDetail,
        theme: SupermuxZeronTheme,
        highlights: SupermuxZeronDiffHighlights? = nil
    ) {
        self.detail = detail
        self.theme = theme
        self.highlights = highlights
    }

    /// The painted height, i.e. the analytic detail height less the hairline
    /// the card draws above it.
    public static func bodyHeight(of detail: SupermuxHarnessChipDetail) -> CGFloat {
        detail.height - Chips.detailSeparator
    }

    public var body: some View {
        switch detail {
        case .output(let lines, let truncatedBy):
            outputBody(lines: lines, truncatedBy: truncatedBy)
        case .stats(let stats):
            statsBody(stats)
        case .diff(let diff):
            SupermuxZeronDiffBody(diff: diff, theme: theme, highlights: highlights)
        }
    }

    // MARK: Output

    /// Verbatim lines, indentation intact, each in its own 18 pt box.
    private func outputBody(lines: [String], truncatedBy: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                SupermuxZeronChipTextRow(
                    text: line,
                    font: SupermuxZeronFonts.mono(size: Chips.outputTextSize),
                    color: theme.text.opacity(Chips.subjectAlpha)
                )
            }
            if truncatedBy > 0 {
                SupermuxZeronChipTextRow(
                    text: Self.countedTailLabel(truncatedBy),
                    font: SupermuxZeronFonts.mono(size: Chips.tailTextSize),
                    color: theme.textFaint
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Chips.outputBodyPad / 2)
        .clipped()
    }

    /// `"… {n} more lines"` — leading U+2026, and **never singularized**, which
    /// is zeron's own wording.
    static func countedTailLabel(_ truncatedBy: Int) -> String {
        String(
            format: String(
                localized: "supermux.zeron.chip.output.moreLines",
                defaultValue: "\u{2026} %lld more lines",
                bundle: .supermuxZeronUI
            ),
            Int64(truncatedBy)
        )
    }

    // MARK: Stats

    /// The thin-doc edit record: one `path  +N  −N` row per file. No counted
    /// tail — `Stats` has none in zeron either.
    private func statsBody(_ stats: [SupermuxHarnessDiffStat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                HStack(spacing: SupermuxZeronMetrics.Theme.spaceSM) {
                    Text(stat.path)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(theme.text.opacity(Chips.subjectAlpha))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "+\(stat.additions)")
                        .foregroundStyle(theme.success)
                        .fixedSize()
                    // U+2212 MINUS SIGN, matching the diff body's marker.
                    Text(verbatim: "\u{2212}\(stat.deletions)")
                        .foregroundStyle(theme.danger)
                        .fixedSize()
                }
                .font(SupermuxZeronFonts.mono(size: Chips.outputTextSize))
                .padding(.horizontal, Chips.outputPadX)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Chips.outputLineHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Chips.outputBodyPad / 2)
        .clipped()
    }
}

// MARK: - One fixed-height mono row

/// A single 18 pt mono line: the primitive both the output body and its counted
/// tail are built from.
///
/// `.lineLimit(1)` plus an explicit box is what makes plan R4's analytic height
/// safe — the content physically cannot push the row taller.
struct SupermuxZeronChipTextRow: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    let text: String
    let font: Font
    let color: Color

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Chips.outputPadX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Chips.outputLineHeight)
    }
}

// MARK: - Separator

/// The 1 pt hairline a card draws above each body block.
///
/// One per body — the invocation block and the detail block each get their own;
/// the blob affordance row gets none.
public struct SupermuxZeronChipSeparator: View {
    private let theme: SupermuxZeronTheme

    public init(theme: SupermuxZeronTheme) { self.theme = theme }

    public var body: some View {
        Rectangle()
            .fill(theme.hairline(0.06))
            .frame(height: SupermuxZeronMetrics.Chips.detailSeparator)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Blob affordance

/// The "Show full output (12 KB)" row appended below an open detail whose full
/// payload lives in a sidecar.
///
/// supermux's Claude Code harness inlines every payload today, so nothing
/// constructs one yet — it exists because the chip's height model has to
/// account for it (`+24` when present) and because the mobile projection is the
/// natural place a sidecar would appear.
public struct SupermuxZeronBlobAffordance: Sendable, Equatable, Hashable, Identifiable {
    /// Which payload is on offer. A diff is offered before an output, and the
    /// currently-displayed ref is skipped so the two can trade places.
    public enum Kind: Sendable, Equatable, Hashable {
        case output
        case diff
    }

    /// The fetch's lifecycle.
    public enum State: Sendable, Equatable, Hashable {
        /// Fetchable. `byteCount` is shown in the label when known.
        case ready(byteCount: Int?)
        case loading
        /// The fetch failed; the row stays tappable to retry.
        case failed
    }

    /// The sidecar reference — also this row's identity.
    public let id: String
    public let kind: Kind
    public let state: State

    public init(id: String, kind: Kind, state: State) {
        self.id = id
        self.kind = kind
        self.state = state
    }

    /// Tappable in every state except `.loading`.
    public var isInteractive: Bool {
        if case .loading = state { return false }
        return true
    }

    /// The row's label, matching zeron's four states.
    public var label: String {
        switch state {
        case .ready(let byteCount):
            guard let byteCount else { return Self.showFull(kind) }
            return Self.showFullSized(kind, size: Self.formatBytes(byteCount))
        case .loading:
            return Self.loading(kind)
        case .failed:
            return Self.failed(kind)
        }
    }

    /// `< 1024 → "{n} B"`, else `"{ceil(n/1024)} KB"`.
    static func formatBytes(_ count: Int) -> String {
        let clamped = max(0, count)
        if clamped < 1024 {
            return String(
                format: String(
                    localized: "supermux.zeron.chip.blob.bytes",
                    defaultValue: "%lld B",
                    bundle: .supermuxZeronUI
                ),
                Int64(clamped)
            )
        }
        let kb = (clamped + 1023) / 1024
        return String(
            format: String(
                localized: "supermux.zeron.chip.blob.kilobytes",
                defaultValue: "%lld KB",
                bundle: .supermuxZeronUI
            ),
            Int64(kb)
        )
    }

    // Each state is a separate key PER KIND rather than one format with an
    // interpolated noun: "output"/"diff" inflects differently in most
    // languages, and a bare noun slot cannot be translated correctly.

    private static func showFull(_ kind: Kind) -> String {
        switch kind {
        case .output:
            String(
                localized: "supermux.zeron.chip.blob.showFull.output",
                defaultValue: "Show full output",
                bundle: .supermuxZeronUI
            )
        case .diff:
            String(
                localized: "supermux.zeron.chip.blob.showFull.diff",
                defaultValue: "Show full diff",
                bundle: .supermuxZeronUI
            )
        }
    }

    private static func showFullSized(_ kind: Kind, size: String) -> String {
        switch kind {
        case .output:
            String(
                format: String(
                    localized: "supermux.zeron.chip.blob.showFullSized.output",
                    defaultValue: "Show full output (%@)",
                    bundle: .supermuxZeronUI
                ),
                size
            )
        case .diff:
            String(
                format: String(
                    localized: "supermux.zeron.chip.blob.showFullSized.diff",
                    defaultValue: "Show full diff (%@)",
                    bundle: .supermuxZeronUI
                ),
                size
            )
        }
    }

    private static func loading(_ kind: Kind) -> String {
        switch kind {
        case .output:
            String(
                localized: "supermux.zeron.chip.blob.loading.output",
                defaultValue: "Loading full output\u{2026}",
                bundle: .supermuxZeronUI
            )
        case .diff:
            String(
                localized: "supermux.zeron.chip.blob.loading.diff",
                defaultValue: "Loading full diff\u{2026}",
                bundle: .supermuxZeronUI
            )
        }
    }

    private static func failed(_ kind: Kind) -> String {
        switch kind {
        case .output:
            String(
                localized: "supermux.zeron.chip.blob.failed.output",
                defaultValue: "Couldn't load full output \u{2014} tap to retry",
                bundle: .supermuxZeronUI
            )
        case .diff:
            String(
                localized: "supermux.zeron.chip.blob.failed.diff",
                defaultValue: "Couldn't load full diff \u{2014} tap to retry",
                bundle: .supermuxZeronUI
            )
        }
    }
}

/// The 24 pt affordance row itself. **No hairline above it** — it sits directly
/// under whichever body came last.
public struct SupermuxZeronBlobAffordanceRow: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    private let affordance: SupermuxZeronBlobAffordance
    private let theme: SupermuxZeronTheme
    private let onTap: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        affordance: SupermuxZeronBlobAffordance,
        theme: SupermuxZeronTheme,
        onTap: @escaping () -> Void
    ) {
        self.affordance = affordance
        self.theme = theme
        self.onTap = onTap
    }

    public var body: some View {
        Text(affordance.label)
            .font(SupermuxZeronFonts.sans(size: Chips.blobAffordanceTextSize))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Chips.blobAffordancePadX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Chips.blobAffordanceHeight)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(
                reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
                value: isHovered
            )
            // A LOADING row is inert in zeron: no `cursor_pointer`, no `.hover`
            // tint, no `on_click`. Attaching a no-op gesture instead would
            // still swallow the tap and still claim the button trait.
            .modifier(
                SupermuxZeronBlobAffordanceInteraction(
                    isEnabled: affordance.isInteractive,
                    onTap: onTap
                )
            )
    }

    /// macOS lifts `textFaint → textMuted` on hover. iOS has no pointer, so it
    /// RESTS at `textMuted` (plan §4) — a permanently dim affordance with no
    /// hover to reveal it reads as disabled.
    private var tint: Color {
        guard affordance.isInteractive else { return theme.textFaint }
        #if os(macOS)
        return isHovered ? theme.textMuted : theme.textFaint
        #else
        return theme.textMuted
        #endif
    }
}

/// Tap, pointer and the button trait — all three, or none of them.
///
/// Split out as a modifier because the three have to appear together: a row
/// that reads as a button to VoiceOver but ignores the activation, or one that
/// shows a link cursor while loading, is worse than an inert row.
private struct SupermuxZeronBlobAffordanceInteraction: ViewModifier {
    let isEnabled: Bool
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onTapGesture(perform: onTap)
                .modifier(SupermuxZeronPointerCursor())
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

// MARK: - Per-chip content

/// Everything an expanded chip renders, resolved ONCE per group body pass.
///
/// `SupermuxHarnessToolCall.detail` re-parses `structuredPatch` and re-truncates
/// the diff on every access, so reading it straight from a `body` would redo
/// that work for every chip on every frame. The group resolves this value once
/// and hands it down.
public struct SupermuxZeronChipContent: Sendable, Equatable {
    private typealias Chips = SupermuxZeronMetrics.Chips

    /// The full, un-flattened call. Almost always present, which is why almost
    /// every chip expands.
    public let invocation: SupermuxHarnessChipDetail?
    /// The result body: diff → stats → output → none, first match wins.
    public let detail: SupermuxHarnessChipDetail?
    /// The sidecar offer, when one exists.
    public let affordance: SupermuxZeronBlobAffordance?

    public init(
        invocation: SupermuxHarnessChipDetail?,
        detail: SupermuxHarnessChipDetail?,
        affordance: SupermuxZeronBlobAffordance? = nil
    ) {
        self.invocation = invocation
        self.detail = detail
        self.affordance = affordance
    }

    public init(tool: SupermuxHarnessToolCall, affordance: SupermuxZeronBlobAffordance? = nil) {
        self.init(
            invocation: tool.invocationBlock,
            detail: tool.detail,
            affordance: affordance
        )
    }

    /// A chip with neither body is inert: no chevron, no tap, no pointer.
    public var isExpandable: Bool { invocation != nil || detail != nil }

    /// What an open chip adds below its 30 pt header row.
    public var expandedExtraHeight: CGFloat {
        (invocation?.height ?? 0)
            + (detail?.height ?? 0)
            + (affordance == nil ? 0 : Chips.blobAffordanceHeight)
    }

    /// The card's height when open.
    public var openCardHeight: CGFloat { Chips.cardHeight + expandedExtraHeight }

    /// The card's height when closed — always the bare header row.
    public var closedCardHeight: CGFloat { Chips.cardHeight }

    /// The card's height for a resolved open state.
    public func cardHeight(isOpen: Bool) -> CGFloat {
        isOpen ? openCardHeight : closedCardHeight
    }
}

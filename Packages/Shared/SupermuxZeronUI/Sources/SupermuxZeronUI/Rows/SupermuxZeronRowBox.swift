//
//  SupermuxZeronRowBox.swift
//  SupermuxZeronUI
//
//  The universal transcript row wrapper. Spec 02 §1.2, §2.
//
//  EVERY transcript row — user, assistant markdown, tool group, chips, notice —
//  is wrapped in the IDENTICAL outer box (`transcript.rs:2923-2966`):
//
//      div()
//        .id(row.id)                 // the hover target for the timestamp reveal
//        .w_full().flex().justify_center()
//        .pt(top_gap)                // §2 — the vertical rhythm lives HERE, as padding
//        .pb(bottom_pad)             // §2.4 — 0 except on the last row
//        .px(48)                     // the wide gutters
//        .child(div().w_full().max_w(736).min_w_0()
//                 .child(inner)      // the row's content
//                 .children(strip)   // the timestamp lane
//                 .children(trailer))// the working indicator, last row only
//
//  Resolved geometry for a viewport of width `W`:
//    inner width = W − 96 · column width = min(W − 96, 736) · centred in W.
//
//  ── The gutter never shrinks ──
//
//  The Rust hardcodes `px(48)` unconditionally even though its own comment cites
//  the web original's `px-4 @3xl:px-12` responsive pair. That is a deliberate
//  simplification in zeron-comet, and the constant is what gets reproduced. iOS
//  is the ONE exception the plan grants (§4): 48 pt gutters on a 390 pt phone
//  leave 294 pt of text, so iOS clamps to `min(48, 16 + safeAreaLeading)`. The
//  736 cap, the centring and the bubble's 588.8 constant do not change.
//
//  ── The gap is PADDING on the row, not spacing between siblings ──
//
//  The transcript is a virtualized list and gpui's list has no inter-item
//  spacing. Reproducing it as `LazyVStack(spacing: 0)` + per-row top padding is
//  not a workaround: it is what makes the gap a property of the row, so a
//  splice that inserts a row cannot change the gap above its neighbour.
//
//  ── Gap selection (`top_gap_for`, spec 02 §2.2) ──
//
//      row 0                                       → 62  (38 titlebar + 14 + 10)
//      turnStart                                   → 14  (GAP_TURN)
//      prev and row BOTH markdown, same part prefix→ 12  (MD_BLOCK_GAP)
//      otherwise                                   →  8  (GAP_BLOCK)
//
//  The markdown case exists because a STREAMING message is one live row whose
//  internal blocks stack with `MD_BLOCK_GAP`; when it completes it splits into
//  one row per block, and those inter-row gaps must equal the old intra-row gaps
//  or the whole message jumps a pixel at completion. zeron proves this with
//  `split_sibling_gaps_match_live_internal_spacing`.
//

public import SupermuxClaudeHarness
public import SwiftUI

/// The universal row wrapper: gap, gutters, centred column, timestamp lane,
/// working trailer.
///
/// Takes immutable values and closures only — it lives below the `LazyVStack`
/// boundary and must never hold an observable store reference (cmux #2586).
public struct SupermuxZeronRowBox<Inner: View>: View {
    /// The gap above this row, from ``SupermuxZeronRowGap``.
    private let topGap: CGFloat
    /// The pad below this row. Zero except on the last row, where it is
    /// `bottomClearance + 24 + 8 + runway (+ safeAreaBottom)`.
    private let bottomPad: CGFloat
    /// The horizontal gutter. 48 on macOS; `min(48, 16 + safeAreaLeading)` on iOS.
    private let gutter: CGFloat
    private let timestamp: Date?
    private let isUserRow: Bool
    private let isTimestampRevealed: Bool
    private let theme: SupermuxZeronTheme
    private let inner: Inner
    /// The working trailer, mounted on the last row only. `nil` otherwise.
    private let trailer: AnyView?

    public init(
        topGap: CGFloat,
        bottomPad: CGFloat = 0,
        gutter: CGFloat = SupermuxZeronMetrics.Transcript.gutter,
        timestamp: Date? = nil,
        isUserRow: Bool,
        isTimestampRevealed: Bool = false,
        theme: SupermuxZeronTheme,
        trailer: AnyView? = nil,
        @ViewBuilder inner: () -> Inner
    ) {
        self.topGap = topGap
        self.bottomPad = bottomPad
        self.gutter = gutter
        self.timestamp = timestamp
        self.isUserRow = isUserRow
        self.isTimestampRevealed = isTimestampRevealed
        self.theme = theme
        self.trailer = trailer
        self.inner = inner()
    }

    public var body: some View {
        HStack(spacing: 0) {
            // `justify_center` on the outer flex: the column is centred, and the
            // gutters are the row's own horizontal padding, so a row wider than
            // the column (a code block, a diff) still clips at the same edges.
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                inner
                SupermuxZeronTimestampLane(
                    timestamp: timestamp,
                    isUserRow: isUserRow,
                    isRevealed: isTimestampRevealed,
                    theme: theme
                )
                if let trailer { trailer }
            }
            .frame(maxWidth: SupermuxZeronMetrics.Transcript.maxContentWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, gutter)
        .padding(.top, topGap)
        .padding(.bottom, bottomPad)
    }
}

// MARK: - Gap selection

/// `top_gap_for` (`transcript.rs:979-992`) plus row 0's special case.
///
/// Pure, so the whole vertical rhythm is unit-testable without a view.
///
/// Its receiver would be `[SupermuxHarnessRow]`, and a row-pair function does
/// not belong on the row model — the data layer must not know about titlebars
/// or fade bands.
///
/// lint:allow namespace-enum, namespace-type — the pure gap rule (spec 02 §2.2).
public enum SupermuxZeronRowGap {
    /// Row 0 carries the titlebar's height inside its own box, because the
    /// transcript viewport spans the full window and scrolls UNDER the titlebar.
    /// `38 + 14 + 10 = 62`.
    public static let row0 = SupermuxZeronMetrics.Transcript.row0TopGap

    /// The gap above `row`, given the row before it and its index.
    ///
    /// - Parameters:
    ///   - index: the row's position. Index 0 always gets ``row0``.
    ///   - previous: the row above, or `nil` at index 0.
    public static func topGap(
        index: Int,
        previous: SupermuxHarnessRow?,
        row: SupermuxHarnessRow
    ) -> CGFloat {
        guard index > 0, let previous else { return row0 }
        return topGap(previous: previous, row: row)
    }

    /// The gap between two adjacent rows.
    public static func topGap(previous: SupermuxHarnessRow, row: SupermuxHarnessRow) -> CGFloat {
        if row.turnStart { return SupermuxZeronMetrics.Transcript.gapTurn }
        if isMarkdown(previous), isMarkdown(row), sharePartPrefix(previous.id, row.id) {
            return SupermuxZeronMetrics.Transcript.mdBlockGap
        }
        return SupermuxZeronMetrics.Transcript.gapBlock
    }

    /// Markdown rows are the prose rows: zeron's `Markdown` and `LiveMarkdown`
    /// both map onto `assistantProse`. Thinking is a group-header primitive, not
    /// a markdown block, so it does not take the 12 pt gap.
    private static func isMarkdown(_ row: SupermuxHarnessRow) -> Bool {
        if case .assistantProse = row.kind { return true }
        return false
    }

    /// "Same part prefix" = the ids agree on everything before the final
    /// separator. zeron's ids are `{entry}#{part}.{blockIx}`; supermux's builder
    /// emits `{entryID}-{blockIndex}`. Both are "everything up to the last
    /// component", so the comparison is on the id minus its trailing index.
    static func sharePartPrefix(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = partPrefix(lhs), let b = partPrefix(rhs) else { return false }
        return a == b
    }

    private static func partPrefix(_ id: String) -> Substring? {
        // Prefer `.` (zeron's block separator) and fall back to `-` (the
        // supermux builder's), so the rule holds for both id shapes and for a
        // wire-decoded row that carried zeron-shaped ids.
        if let dot = id.lastIndex(of: ".") { return id[id.startIndex..<dot] }
        if let dash = id.lastIndex(of: "-") { return id[id.startIndex..<dash] }
        return nil
    }
}

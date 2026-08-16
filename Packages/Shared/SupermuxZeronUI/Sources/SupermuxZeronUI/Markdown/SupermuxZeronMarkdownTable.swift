//
//  SupermuxZeronMarkdownTable.swift
//  SupermuxZeronUI
//
//  GFM tables. Spec 05 §2.9, `render.rs:376-489`.
//
//  ── The chrome is one thing: hairlines BETWEEN rows ──
//
//  "The design is frameless ('flat hairline'): 1px horizontal rules under the
//  header and between rows are the only chrome — no outer box, no header fill,
//  no corner radius." There are also no vertical rules and no zebra striping.
//  A header plus two rows draws exactly TWO hairlines, because a rule is
//  emitted for every row index > 0.
//
//  ── Column widths are content-proportional, never equal thirds ──
//
//  This reproduces the source CSS `flex: <max-content> <max-content> 0;
//  min-width: min(max-content, 96px)`:
//
//      natural[c] = max(measuredContent[c], 48) + 2 × 12
//      minimum[c] = min(natural[c], 96)
//      minTableWidth = Σ minimum
//
//  When even the floors no longer fit, the table SCROLLS HORIZONTALLY rather
//  than crushing every column into per-character wrapping.
//

internal import SwiftUI

public import CoreGraphics

internal import Foundation

// MARK: - Column geometry

/// Resolved per-column table geometry — the port of `table_columns`
/// (`render.rs:342`).
///
/// This reproduces the source CSS `flex: <max-content> <max-content> 0;
/// min-width: min(max-content, 96px)`. Padding is added HERE, because the
/// source adds `2 × cellPadding` at this step:
///
/// ```
/// natural[c] = max(measuredContent[c], 48) + 2 × 12
/// minimum[c] = min(natural[c], 96)
/// ```
///
/// Widths are content-proportional, never equal fractions. Worked example from
/// the Rust's own unit test: content `[10, 200]` → naturals `[72, 224]`,
/// minimums `[72, 96]`, min table width `168`.
public struct SupermuxZeronTableColumns: Sendable, Equatable {
    /// Per-column max-content width, padding INCLUDED.
    public let naturals: [CGFloat]
    /// `min(natural, 96)` — the floor a column stops shrinking at.
    public let minimums: [CGFloat]
    /// Σ minimums: the width below which the table stops shrinking and SCROLLS
    /// horizontally rather than crushing columns into per-character wrapping.
    public let minTableWidth: CGFloat

    public init(contentWidths: [CGFloat]) {
        let metrics = SupermuxZeronMetrics.Markdown.self
        naturals = contentWidths.map {
            max($0, metrics.tableMinColContent) + 2 * metrics.tableCellPadding
        }
        minimums = naturals.map { min($0, metrics.tableMinColWidth) }
        minTableWidth = minimums.reduce(0, +)
    }

    /// Resolve the RENDERED column widths for an available width.
    ///
    /// This is the flex resolution the source CSS describes
    /// (`flex: <natural> <natural> 0; min-width: <minimum>`) done by hand,
    /// because SwiftUI has no equivalent — spec 05 §9.2 says so outright:
    /// *"no direct equivalent — compute widths yourself … then distribute the
    /// available width proportionally to naturals but never below minimums."*
    ///
    /// `flex-basis: 0` is the load-bearing part: the ENTIRE available width is
    /// distributed by grow factor, so a column's share is
    /// `available × natural / Σnatural` — content-PROPORTIONAL, never equal
    /// fractions (zeron unit-tests exactly that, `render.rs:1355-1362`). A
    /// column that would fall under its floor freezes at the floor and the
    /// remainder redistributes among the rest, which is what a real flex pass
    /// does. Below ``minTableWidth`` every column sits on its floor and the
    /// table scrolls instead of shrinking further.
    public func resolved(available: CGFloat) -> [CGFloat] {
        guard !naturals.isEmpty else { return [] }
        guard available > minTableWidth else { return minimums }

        var widths = minimums
        var frozen = [Bool](repeating: false, count: naturals.count)
        // At most one freeze per column, so the loop is bounded by the count.
        for _ in 0..<naturals.count {
            let free = available - zip(widths, frozen)
                .filter(\.1).map(\.0).reduce(0, +)
            let share = zip(naturals, frozen)
                .filter { !$0.1 }.map(\.0).reduce(0, +)
            guard share > 0 else { break }
            var froze = false
            for index in naturals.indices where !frozen[index] {
                let proportional = free * naturals[index] / share
                if proportional < minimums[index] {
                    widths[index] = minimums[index]
                    frozen[index] = true
                    froze = true
                } else {
                    widths[index] = proportional
                }
            }
            if !froze { break }
        }
        return widths
    }
}

/// A rendered GFM table.
struct SupermuxZeronMarkdownTable: View {
    private typealias Md = SupermuxZeronMetrics.Markdown

    let header: [[SupermuxZeronInlineRun]]
    let rows: [[[SupermuxZeronInlineRun]]]
    let align: [SupermuxZeronTableAlign]
    let theme: SupermuxZeronTheme
    let elementID: Int
    let veilSpans: [Int: [SupermuxZeronVeilSpan]]
    let onOpenURL: ((URL) -> Void)?

    /// Header first, then the body rows — one uniform list, which is what makes
    /// "a hairline for every index > 0" the whole chrome rule.
    private var allRows: [[[SupermuxZeronInlineRun]]] {
        header.isEmpty ? rows : [header] + rows
    }

    /// Ragged rows are tolerated: the column count is the widest row, and a
    /// missing cell renders as an empty padded box.
    private var columnCount: Int {
        allRows.map(\.count).max() ?? 0
    }

    var body: some View {
        let geometry = Self.columns(contentWidths: measuredContentWidths)
        // The available width has to be read before the columns can be resolved,
        // and the resolution is what decides the rows' width — so the reader
        // supplies the input and the content sizes itself from it.
        GeometryReader { proxy in
            let widths = geometry.resolved(available: proxy.size.width)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(allRows.enumerated()), id: \.offset) { rowIndex, row in
                        if rowIndex > 0 {
                            Rectangle()
                                .fill(theme.hairline(Md.tableDividerAlpha))
                                .frame(height: Md.tableDividerWidth)
                                .frame(maxWidth: .infinity)
                        }
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<columnCount, id: \.self) { column in
                                cell(
                                    row.indices.contains(column) ? row[column] : [],
                                    rowIndex: rowIndex,
                                    column: column,
                                    width: widths[column]
                                )
                            }
                        }
                    }
                }
                // Never narrower than the floors; below that the scroller runs.
                .frame(
                    width: max(widths.reduce(0, +), geometry.minTableWidth),
                    alignment: .leading
                )
            }
        }
        .frame(height: measuredHeight)
    }

    /// The table's own height, measured from the resolved column widths.
    ///
    /// A `GeometryReader` reports its parent's width but proposes nothing back,
    /// so the height has to be computed rather than inferred. Every cell is a
    /// fixed 22 pt line box plus 2 × 12 pt padding, and a row is as tall as its
    /// tallest cell.
    private var measuredHeight: CGFloat {
        let geometry = Self.columns(contentWidths: measuredContentWidths)
        let widths = geometry.resolved(available: geometry.naturals.reduce(0, +))
        var total: CGFloat = 0
        for (rowIndex, row) in allRows.enumerated() {
            if rowIndex > 0 { total += Md.tableDividerWidth }
            var tallest = Md.lineHeight
            for column in 0..<columnCount where row.indices.contains(column) {
                let isHeader = rowIndex == 0 && !header.isEmpty
                let flat = SupermuxZeronFlatText.flatten(
                    runs: row[column],
                    theme: theme,
                    baseWeight: isHeader ? .bold : .regular
                )
                let inner = max(widths[column] - 2 * Md.tableCellPadding, 1)
                let layout = SupermuxZeronTextKit.layout(
                    attributed: SupermuxZeronTextKit.attributedString(
                        for: flat,
                        fontSize: Md.textSize,
                        lineHeight: Md.lineHeight,
                        theme: theme
                    ),
                    text: flat.text,
                    width: inner,
                    codeRanges: flat.codeRanges,
                    links: flat.links
                )
                tallest = max(tallest, layout.height)
            }
            total += tallest + 2 * Md.tableCellPadding
        }
        return total
    }

    private func cell(
        _ runs: [SupermuxZeronInlineRun],
        rowIndex: Int,
        column: Int,
        width: CGFloat
    ) -> some View {
        // A header cell flattens at base weight 700. A strong run INSIDE a
        // header stays 700 and never drops to 600, because the promotion only
        // fires when the base is below semibold.
        let isHeader = rowIndex == 0 && !header.isEmpty
        let flat = SupermuxZeronFlatText.flatten(
            runs: runs,
            theme: theme,
            baseWeight: isHeader ? .bold : .regular
        )
        let id = elementID * 100_000 + rowIndex * 100 + column
        return SupermuxZeronMarkdownText(
            flat: flat,
            fontSize: Md.textSize,
            lineHeight: Md.lineHeight,
            theme: theme,
            veilSpans: veilSpans[id] ?? [],
            onOpenURL: onOpenURL
        )
        .frame(
            maxWidth: .infinity,
            alignment: alignment(column)
        )
        // Uniform 12 pt on all four sides, inside the resolved column width.
        .padding(Md.tableCellPadding)
        .frame(width: width, alignment: alignment(column))
    }

    private func alignment(_ column: Int) -> Alignment {
        switch align.indices.contains(column) ? align[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    // MARK: Column geometry

    /// `table_columns` (`render.rs:342`), as a pure function so it is testable
    /// without a view. See ``SupermuxZeronTableColumns``.
    static func columns(contentWidths: [CGFloat]) -> SupermuxZeronTableColumns {
        SupermuxZeronTableColumns(contentWidths: contentWidths)
    }

    /// Per-column max-content width: each cell's flat text shaped UNWRAPPED at
    /// 14 pt with its own runs, newlines replaced by spaces.
    private var measuredContentWidths: [CGFloat] {
        (0..<columnCount).map { column in
            allRows.enumerated().reduce(CGFloat(0)) { widest, entry in
                let (rowIndex, row) = entry
                guard row.indices.contains(column) else { return widest }
                let isHeader = rowIndex == 0 && !header.isEmpty
                let flat = SupermuxZeronFlatText.flatten(
                    runs: row[column],
                    theme: theme,
                    baseWeight: isHeader ? .bold : .regular
                )
                return max(widest, Self.unwrappedWidth(flat))
            }
        }
    }

    /// The unwrapped width of a flat cell.
    private static func unwrappedWidth(_ flat: SupermuxZeronFlatText) -> CGFloat {
        var width: CGFloat = 0
        for run in flat.runs {
            let font = run.isMono
                ? SupermuxZeronFonts.platformMono(size: Md.textSize, weight: run.weight)
                : SupermuxZeronFonts.platformSans(size: Md.textSize, weight: run.weight)
            let text = run.text.replacingOccurrences(of: "\n", with: " ")
            width += (text as NSString).size(withAttributes: [.font: font]).width
        }
        return width.rounded(.up)
    }
}

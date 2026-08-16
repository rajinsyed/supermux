//
//  SupermuxZeronGradientSpinner.swift
//  SupermuxZeronUI
//
//  The 3×3 dot-matrix working spinner (`crates/ui/src/loaders.rs:113-145`),
//  spec 07 §5.3. This is the ONLY loader the chat pane uses.
//
//  Geometry at the chat pane's `cell = 2.5`:
//
//      cell        2.5 × 2.5 pt, radius 1.25 (a circle)
//      row gap     1.25    column gap 1.25
//      footprint   3·cell + 2·(cell/2) = 4·cell = 10 × 10 pt
//
//  The wave enters at the bottom edge and converges on the top-centre cell, so
//  it reads as travelling UPWARD: bottom-centre leads at phase 0, the top
//  corners trail at 0.75. Row tints are theme-INDEPENDENT — `gradient_spinner`
//  takes a `&Theme` and ignores it — and the tint is always painted at full
//  saturation with only opacity animating. Do NOT desaturate a dim cell; the
//  screenshot cross-check confirms dim cells are visibly tinted (row 2 col 1
//  reads (37,35,32) against a (21,21,21) backdrop).
//
//  Frames come from the shared 30 fps ``SupermuxZeronPulseClock``, never from
//  `.repeatForever` or `TimelineView(.animation)` (plan R12).
//

public import SwiftUI

/// The 3×3 gradient spinner.
///
/// ```swift
/// SupermuxZeronGradientSpinner(leaseID: "working-indicator")   // 10 × 10 pt
/// ```
public struct SupermuxZeronGradientSpinner: View {
    /// The lease identity this spinner renews on the shared clock. Stable per
    /// mounted spinner; zeron uses `"working-indicator"` and `"sending-indicator"`.
    private let leaseID: String
    /// Cell edge in points. The chat pane always passes 2.5.
    private let cell: CGFloat

    @Environment(\.supermuxZeronPulseClock) private var clockOverride
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        leaseID: String,
        cell: CGFloat = SupermuxZeronMetrics.Loaders.matrixCellSize
    ) {
        self.leaseID = leaseID
        self.cell = cell
    }

    /// `cell / 2`, used for both gaps and the corner radius.
    private var half: CGFloat { cell / 2 }

    /// `4 · cell` per side — 10 × 10 pt at the chat pane's 2.5.
    private var footprint: CGFloat { cell * 4 }

    public var body: some View {
        // Reading the phase here renews the lease and subscribes this view to
        // the clock's frame counter. It is a READ of published state, never a
        // write — the list-boundary rule forbids a `body` function that mutates
        // view state, and lease renewal is the clock's own bookkeeping.
        let clock = clockOverride ?? SupermuxZeronPulseClock.shared
        let delta = clock.phase(
            period: Double(SupermuxZeronMetrics.Motion.gradientSpin.durationMS) / 1000,
            leasedBy: leaseID,
            reduceMotion: reduceMotion
        )
        let side = SupermuxZeronMetrics.Loaders.matrixSide

        VStack(spacing: half) {
            ForEach(0..<side, id: \.self) { row in
                HStack(spacing: half) {
                    ForEach(0..<side, id: \.self) { column in
                        Circle()
                            .fill(Self.tint(row: row))
                            .frame(width: cell, height: cell)
                            .opacity(
                                SupermuxZeronMetrics.Loaders.gspinOpacity(
                                    delta + SupermuxZeronMetrics.Loaders.matrixCellPhase(
                                        row: row,
                                        col: column
                                    )
                                )
                            )
                    }
                }
            }
        }
        .frame(width: footprint, height: footprint)
        // One accessibility element, not nine dots.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                String(
                    localized: "supermux.zeron.loader.working",
                    defaultValue: "Working",
                    bundle: .supermuxZeronUI
                )
            )
        )
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// One tint per ROW — all three cells of a row share it. zeron's "sunrise"
    /// gradient sampled per row: cool blue top, amber middle, pink bottom.
    private static func tint(row: Int) -> Color {
        let tints = SupermuxZeronTheme.gradientSpinnerRowTints
        return tints[min(max(row, 0), tints.count - 1)]
    }
}

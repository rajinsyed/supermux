import SwiftUI

/// Shared geometry for the usage sheet, so its content and its measured
/// height agree on one set of numbers.
/// lint:allow namespace-enum — layout constants shared by the sheet's content and its height measurement.
enum SupermuxUsageMetrics {
    /// Inset from the sheet's edge to its content.
    static let contentInset: CGFloat = 20
    /// Floor for the fitted sheet height, so the sheet never opens as a
    /// sliver in the frame before the first measurement lands.
    static let minimumSheetHeight: CGFloat = 160

    /// The sheet's ground: the system's glass over an OPAQUE base.
    ///
    /// Glass alone is not a ground. It samples the workspace list behind the
    /// sheet, and with the rows sitting directly on it that list's text reads
    /// straight through the meter labels. The opaque layer stops that while
    /// the glass above it keeps the floating-panel look.
    static var sheetFill: some ShapeStyle {
        #if os(iOS)
        Color(uiColor: .systemBackground).opacity(0.82)
        #else
        Color(nsColor: .windowBackgroundColor).opacity(0.82)
        #endif
    }
}

extension View {
    /// Presents the usage card as a sheet sized to its own content.
    ///
    /// The tracker is a summary dial plus a handful of meter rows, so a
    /// full-height sheet would be mostly empty and would hide the workspace
    /// list for no reason. The content measures its natural height and asks
    /// for exactly that as a custom detent, so the sheet stops where the
    /// content does — which on iOS 26 also keeps it in the system's floating
    /// Liquid Glass presentation, since that is what a partial-height sheet
    /// renders as. A full-height sheet would drop back to the opaque,
    /// edge-attached appearance.
    ///
    /// - Parameters:
    ///   - isPresented: Whether the card is showing.
    ///   - card: The card's content (see ``SupermuxUsageScreen``).
    func supermuxUsageSheet(
        isPresented: Binding<Bool>,
        @ViewBuilder card: @escaping () -> some View
    ) -> some View {
        sheet(isPresented: isPresented) {
            SupermuxUsageFittedSheet(card: card)
        }
    }
}

/// Sizes the usage sheet to its content.
///
/// Height comes from measuring the content rather than from a fixed detent:
/// the row count varies with how many cswap accounts and scoped limits the Mac
/// reports, and any fixed detent would be wrong for most of them.
///
/// The measurement cannot feed back into itself. The content sits in a
/// `ScrollView`, which proposes an unbounded height in its scroll axis, so the
/// content always lays out at its IDEAL height regardless of the sheet's
/// current detent — and when that ideal exceeds what the system will grant,
/// the same `ScrollView` scrolls instead of the content clipping. An
/// over-large `.height` detent is clamped by the system rather than
/// overflowing.
private struct SupermuxUsageFittedSheet<Card: View>: View {
    @ViewBuilder let card: () -> Card

    /// Measured content height. Distinct from ``detent`` so measurement never
    /// drives the sheet directly: growth is applied by SELECTING a new detent
    /// out of a set that already contains it, which is what animates.
    @State private var contentHeight: CGFloat = 0
    @State private var detent: PresentationDetent = .height(SupermuxUsageMetrics.minimumSheetHeight)
    /// Every height the sheet has settled at this presentation. Replacing a
    /// single-element detent set makes the sheet JUMP to the new size; only
    /// moving the selection between detents already in the set animates, so
    /// prior heights stay in the set for the life of the sheet.
    @State private var detents: Set<PresentationDetent> = [
        .height(SupermuxUsageMetrics.minimumSheetHeight),
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            card()
                .padding(SupermuxUsageMetrics.contentInset)
                // Measured OUTSIDE the padding, so the detent covers the
                // content and its inset rather than the content alone.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { measured in
                    apply(measured: measured)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        // The rows sit directly on the sheet, so the sheet itself has to be
        // their ground. Left to the system's glass alone, the blurred
        // workspace list reads straight through the meter labels.
        .presentationBackground(SupermuxUsageMetrics.sheetFill)
        .presentationDetents(detents, selection: $detent)
        .presentationDragIndicator(.visible)
    }

    /// Adopts a new measured height: adds it to the available detents, then
    /// selects it so the sheet animates to it.
    private func apply(measured: CGFloat) {
        let height = max(SupermuxUsageMetrics.minimumSheetHeight, measured.rounded())
        // Subpixel churn (a rolling percent, a countdown losing a digit) must
        // not resize the sheet or grow the detent set unboundedly.
        guard abs(height - contentHeight) > 1 else { return }
        contentHeight = height
        let target = PresentationDetent.height(height)
        detents.insert(target)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            detent = target
        }
    }
}

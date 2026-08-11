import SwiftUI

/// The usage sheet's inner surfaces and the geometry the sheet measures
/// itself against.
///
/// The CARD is the sheet itself: on iOS 26 a partial-height sheet already
/// renders as a floating Liquid Glass panel, so this deliberately adds no
/// glass of its own. Wrapping the content in a second `glassEffect` over a
/// cleared presentation background stacks two glass layers — the system's
/// around the sheet and ours inside it — which reads as a card in a card.
/// What is left here is the quieter fill that groups one provider's rows.
extension View {
    /// One provider's panel inside the sheet: a quiet fill that groups its
    /// rows without drawing a hard edge inside the sheet's own glass.
    ///
    /// The fill is OPAQUE, not a tint. The sheet's glass samples the workspace
    /// list behind it, and a translucent panel lets that list's text ghost up
    /// through the meter labels — legible rows need their own ground. The
    /// glass still reads, in the margins and the gap between panels.
    func supermuxUsagePanel() -> some View {
        let shape = RoundedRectangle(
            cornerRadius: SupermuxUsageMetrics.panelRadius,
            style: .continuous
        )
        return padding(SupermuxUsageMetrics.panelPadding)
            .background(SupermuxUsageMetrics.panelFill, in: shape)
    }
}

/// Shared geometry for the usage sheet, so its panels and its measured height
/// agree on one set of numbers.
/// lint:allow namespace-enum — layout constants shared by the sheet's panels and its height measurement.
enum SupermuxUsageMetrics {
    /// A provider panel's corner radius, concentric with the sheet's own
    /// corner once the content inset is taken off it.
    static let panelRadius: CGFloat = 18
    /// Inset from a provider panel's edge to its rows.
    static let panelPadding: CGFloat = 14
    /// Inset from the sheet's edge to its content.
    static let contentInset: CGFloat = 16
    /// Floor for the fitted sheet height, so the sheet never opens as a
    /// sliver in the frame before the first measurement lands.
    static let minimumSheetHeight: CGFloat = 200

    /// A provider panel's ground. Deliberately an OPAQUE system color rather
    /// than a `.background`/material shape style: inside the sheet's glass
    /// those resolve translucent, and the blurred workspace list then ghosts
    /// up through the meter labels.
    static var panelFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

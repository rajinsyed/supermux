public import SupermuxMobileCore
public import SwiftUI

/// The compact toolbar gauge: a thin ring filled to the tightest usage
/// window, colored by severity — the phone's twin of the Mac sidebar footer
/// button's icon.
///
/// Before any data arrives it renders an empty ring in the secondary label
/// color, so the toolbar slot reads as an icon rather than a gap.
public struct SupermuxUsageGauge: View {
    private let window: SupermuxUsageWindowDTO?
    private let pointSize: CGFloat

    /// Creates a gauge.
    /// - Parameters:
    ///   - window: The tightest window, or `nil` before data arrives.
    ///   - pointSize: The ring's diameter.
    public init(window: SupermuxUsageWindowDTO?, pointSize: CGFloat = 17) {
        self.window = window
        self.pointSize = pointSize
    }

    public var body: some View {
        let lineWidth = max(1.5, pointSize / 8)
        ZStack {
            // Track opacity steps up while empty so the pre-data button reads
            // as an icon, not a blank slot.
            Circle()
                .stroke(Color.primary.opacity(window == nil ? 0.35 : 0.16), lineWidth: lineWidth)
            if let window {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, window.clampedPercent / 100)))
                    .stroke(
                        SupermuxUsageStyle.color(for: window.severity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: pointSize, height: pointSize)
        // Poll updates ease the ring to its new fill instead of jumping.
        .animation(.smooth(duration: 0.6), value: window?.percent)
    }
}

/// Shared presentation rules for the phone's usage surfaces, kept off the
/// views so severity coloring and percent text are unit-testable and cannot
/// drift between the gauge and the meter rows.
/// lint:allow namespace-enum — stateless presentation helpers shared by the gauge and the sheet's rows.
public enum SupermuxUsageStyle {
    /// The color for one severity bucket. Matches the Mac popover's mapping,
    /// so a limit that reads amber in the sidebar reads amber on the phone.
    /// - Parameter severity: The window's severity bucket.
    public static func color(for severity: SupermuxUsageSeverity) -> Color {
        switch severity {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    /// Whole-percent text like "29%". The bars are compact UI; fractional
    /// digits only add noise.
    /// - Parameter percent: The raw percent (clamped into 0–100 here).
    public static func percentText(_ percent: Double) -> String {
        "\(Int(min(100, max(0, percent)).rounded()))%"
    }
}

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .stroke(Color.primary.opacity(window == nil ? 0.35 : 0.14), lineWidth: lineWidth)
            if let window {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, window.clampedPercent / 100)))
                    .stroke(
                        SupermuxUsageStyle.gradient(for: window.severity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: pointSize, height: pointSize)
        // Poll updates ease the ring to its new fill instead of jumping.
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: window?.percent)
    }
}

/// Shared presentation rules for the phone's usage surfaces, kept off the
/// views so severity coloring, window labels, and percent text are
/// unit-testable and cannot drift between the gauge, the dial, and the rows.
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

    /// The fill for a ring or bar: the severity color eased into a lighter
    /// leading edge, so a long bar reads as a gradient rather than a flat
    /// block. Both stops come from the same hue, so severity stays readable.
    /// - Parameter severity: The window's severity bucket.
    public static func gradient(for severity: SupermuxUsageSeverity) -> LinearGradient {
        let tint = color(for: severity)
        return LinearGradient(
            colors: [tint.opacity(0.62), tint],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Whole-percent text like "29%". The bars are compact UI; fractional
    /// digits only add noise.
    /// - Parameter percent: The raw percent (clamped into 0–100 here).
    public static func percentText(_ percent: Double) -> String {
        "\(Int(min(100, max(0, percent)).rounded()))%"
    }

    /// A window's row label. The session and weekly kinds are named here (each
    /// platform owns its own localization); a scoped window carries the
    /// provider's own label.
    /// - Parameter window: The window to name.
    public static func label(for window: SupermuxUsageWindowDTO) -> String {
        switch window.kind {
        case SupermuxUsageWindowDTO.sessionKind:
            String(localized: "supermux.usage.window.session", defaultValue: "5-hour", bundle: .module)
        case SupermuxUsageWindowDTO.weeklyKind:
            String(localized: "supermux.usage.window.weekly", defaultValue: "Weekly", bundle: .module)
        default:
            window.label ?? String(
                localized: "supermux.usage.window.scoped",
                defaultValue: "Scoped",
                bundle: .module
            )
        }
    }
}

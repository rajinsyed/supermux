public import SwiftUI

/// The compact sidebar-footer gauge: a thin ring filled to the tightest
/// usage window's percent, colored by severity. Before any data arrives it
/// renders an empty ring in the secondary label color, matching the footer's
/// other monochrome icons.
public struct SupermuxUsageGaugeIcon: View {
    private let window: SupermuxUsageWindow?
    private let pointSize: CGFloat

    public init(window: SupermuxUsageWindow?, pointSize: CGFloat) {
        self.window = window
        self.pointSize = pointSize
    }

    public var body: some View {
        let lineWidth = max(1.5, pointSize / 8)
        ZStack {
            // Track opacity steps up while empty so the pre-data button reads
            // as an icon (like the neighboring footer glyphs), not a blank slot.
            Circle()
                .stroke(Color.primary.opacity(window == nil ? 0.35 : 0.16), lineWidth: lineWidth)
            if let window {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, window.percent / 100)))
                    .stroke(
                        SupermuxUsageBarRow.color(for: window.severity),
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

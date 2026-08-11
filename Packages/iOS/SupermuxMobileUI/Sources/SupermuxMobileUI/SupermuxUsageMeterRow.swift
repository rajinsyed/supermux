public import SupermuxMobileCore
public import SwiftUI

/// One usage window as a two-line block: label and percent on the baseline,
/// a slim capsule track beneath it, and the reset countdown trailing.
///
/// The phone twin of the Mac popover's `SupermuxUsageBarRow`, sized for touch
/// rather than for a 264pt popover. Text sits ABOVE the bar rather than on top
/// of a tinted fill, so the percent never has to stay legible against a moving
/// background and the fill can carry full-strength color.
///
/// The fill sweeps in from zero on first appearance and live percent changes
/// animate both the fill and the rolling digits; decorative motion is skipped
/// under Reduce Motion.
public struct SupermuxUsageMeterRow: View {
    private let window: SupermuxUsageWindowDTO
    private let appearDelay: TimeInterval
    private let isCompact: Bool

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Creates a meter row.
    /// - Parameters:
    ///   - window: The window to render.
    ///   - appearDelay: Per-row stagger for the appear sweep; 0 means none.
    ///   - isCompact: Tighter type and a thinner bar, for the nested rows
    ///     under an expanded secondary account.
    public init(
        window: SupermuxUsageWindowDTO,
        appearDelay: TimeInterval = 0,
        isCompact: Bool = false
    ) {
        self.window = window
        self.appearDelay = appearDelay
        self.isCompact = isCompact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SupermuxUsageStyle.label(for: window))
                    .font(isCompact ? .caption : .subheadline.weight(.medium))
                    .foregroundStyle(isCompact ? .secondary : .primary)
                    .lineLimit(1)
                // cswap's pace marker: usage is outrunning the elapsed
                // fraction of the weekly window.
                if window.aheadOfPace == true {
                    paceBadge
                }
                Spacer(minLength: 8)
                if let resetsAt = window.resetDate, resetsAt > Date() {
                    Text(String(
                        format: String(
                            localized: "supermux.usage.resets",
                            defaultValue: "resets %@",
                            bundle: .module
                        ),
                        SupermuxUsageCountdown.text(until: resetsAt)
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Text(verbatim: SupermuxUsageStyle.percentText(window.clampedPercent))
                    .font(
                        isCompact
                            ? .caption.weight(.semibold).monospacedDigit()
                            : .subheadline.weight(.semibold).monospacedDigit()
                    )
                    .foregroundStyle(SupermuxUsageStyle.color(for: window.severity))
                    .contentTransition(
                        reduceMotion ? .identity : .numericText(value: window.clampedPercent)
                    )
                    .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: window.clampedPercent)
            }
            track
        }
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.smooth(duration: 0.55).delay(appearDelay)) {
                    hasAppeared = true
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// A quiet capsule track with a severity-tinted capsule fill. The fill
    /// keeps a minimum width so a 1% window still reads as a mark rather than
    /// as an empty track.
    private var track: some View {
        let height: CGFloat = isCompact ? 4 : 6
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                Capsule(style: .continuous)
                    .fill(SupermuxUsageStyle.gradient(for: window.severity))
                    .frame(width: max(height, proxy.size.width * displayedPercent / 100))
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.5),
                        value: window.clampedPercent
                    )
            }
        }
        .frame(height: height)
    }

    private var paceBadge: some View {
        Text(String(
            localized: "supermux.usage.aheadOfPace",
            defaultValue: "ahead of pace",
            bundle: .module
        ))
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.16)))
        .foregroundStyle(.orange)
        .lineLimit(1)
    }

    /// Zero until the appear sweep starts, then the live value.
    private var displayedPercent: Double {
        hasAppeared ? window.clampedPercent : 0
    }

    private var accessibilityText: String {
        String(
            format: String(
                localized: "supermux.usage.window.accessibility",
                defaultValue: "%1$@ window at %2$lld percent",
                bundle: .module
            ),
            SupermuxUsageStyle.label(for: window),
            Int(window.clampedPercent.rounded())
        )
    }
}

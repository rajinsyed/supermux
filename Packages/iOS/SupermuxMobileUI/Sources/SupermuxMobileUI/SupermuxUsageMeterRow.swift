public import SupermuxMobileCore
public import SwiftUI

/// One usage window as a single-line "meter" row: the progress fill sits
/// behind the text (label left, reset countdown and percent right), so each
/// window costs one compact line instead of a label line plus a bar line.
///
/// The phone twin of the Mac popover's `SupermuxUsageBarRow`, sized for touch
/// (larger type, a taller bar) rather than for a 264pt popover. The fill
/// sweeps in from zero on first appearance and live percent changes animate
/// both the fill and the rolling digits; decorative motion is skipped under
/// Reduce Motion.
public struct SupermuxUsageMeterRow: View {
    private let window: SupermuxUsageWindowDTO
    private let appearDelay: TimeInterval

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Creates a meter row.
    /// - Parameters:
    ///   - window: The window to render.
    ///   - appearDelay: Per-row stagger for the appear sweep; 0 means none.
    public init(window: SupermuxUsageWindowDTO, appearDelay: TimeInterval = 0) {
        self.window = window
        self.appearDelay = appearDelay
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            // cswap's pace marker: usage is outrunning the elapsed fraction
            // of the weekly window.
            if window.aheadOfPace == true {
                Text(String(
                    localized: "supermux.usage.aheadOfPace",
                    defaultValue: "ahead of pace",
                    bundle: .module
                ))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
                .foregroundStyle(.orange)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let resetsAt = window.resetDate, resetsAt > Date() {
                Text(String(
                    format: String(
                        localized: "supermux.usage.resets",
                        defaultValue: "resets %@",
                        bundle: .module
                    ),
                    SupermuxUsageCountdown.text(until: resetsAt)
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Text(verbatim: SupermuxUsageStyle.percentText(window.clampedPercent))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(SupermuxUsageStyle.color(for: window.severity))
                .frame(minWidth: 40, alignment: .trailing)
                .contentTransition(reduceMotion ? .identity : .numericText(value: window.clampedPercent))
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: window.clampedPercent)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(meterFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    /// Quiet track with a severity-tinted fill proportional to usage; text
    /// stays legible because the tint stays under ~30% opacity.
    private var meterFill: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                if window.clampedPercent > 0 {
                    Rectangle()
                        .fill(SupermuxUsageStyle.color(for: window.severity).opacity(0.3))
                        .frame(width: max(8, proxy.size.width * displayedPercent / 100))
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.5),
                            value: window.clampedPercent
                        )
                }
            }
        }
    }

    /// Zero until the appear sweep starts, then the live value.
    private var displayedPercent: Double {
        hasAppeared ? window.clampedPercent : 0
    }

    /// The session and weekly kinds are labeled here (each platform owns its
    /// own localization); a scoped window carries the provider's own label.
    private var label: String {
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

    private var accessibilityText: String {
        String(
            format: String(
                localized: "supermux.usage.window.accessibility",
                defaultValue: "%1$@ window at %2$lld percent",
                bundle: .module
            ),
            label,
            Int(window.clampedPercent.rounded())
        )
    }
}

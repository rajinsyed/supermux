import SwiftUI

/// The daily strip under the cost headline: one thin bar per local day, a
/// baseline rule, and only the first/middle/last date as an axis.
///
/// Hand-rolled rather than Swift Charts: at 90 days across ~276pt each bar is
/// ~2pt wide, which wants deterministic width distribution and a stripped axis
/// rather than a chart framework's defaults — and Charts' per-point readouts
/// are hover-driven, which is unusable here (NSPopover-hosted SwiftUI hover
/// regions track with a vertical offset). The peak is therefore labelled
/// inline and tinted in place, so the one interesting value in the strip is
/// readable without pointing at anything.
struct SupermuxUsageAnalyticsChart: View {
    /// What the bars encode. Cost is preferred; a range whose models are all
    /// unpriced would draw a flat zero line, so it falls back to tokens rather
    /// than implying those days were free.
    enum Metric {
        case cost
        case tokens
    }

    let days: [SupermuxDailyUsage]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private static let plotHeight: CGFloat = 44
    /// Idle days keep a visible stub so the baseline reads as continuous.
    private static let minBarHeight: CGFloat = 1.5

    var body: some View {
        let stats = Stats(days: days)
        return VStack(alignment: .leading, spacing: 5) {
            header(stats)
            plot(stats)
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
            axis
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(stats))
    }

    // MARK: - Pieces

    private func header(_ stats: Stats) -> some View {
        HStack(spacing: 6) {
            Text(Self.metricLabel(stats.metric))
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Spacer(minLength: 4)
            if stats.peak > 0 {
                Text(String(
                    format: String(localized: "supermux.analytics.chart.peak", defaultValue: "peak %@"),
                    Self.valueText(stats.peak, metric: stats.metric)
                ))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
    }

    /// Bars share the width through flexible frames, so no rounding remainder
    /// piles up at one end of a 90-day range.
    private func plot(_ stats: Stats) -> some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(days) { day in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(fill(for: day, stats: stats))
                    .frame(height: barHeight(for: day, stats: stats))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.plotHeight, alignment: .bottom)
        .scaleEffect(x: 1, y: hasAppeared ? 1 : 0.02, anchor: .bottom)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: stats.peak)
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.smooth(duration: 0.5)) { hasAppeared = true }
            }
        }
    }

    private var axis: some View {
        HStack(spacing: 4) {
            Text(verbatim: Self.dateLabel(days.first?.day))
            Spacer(minLength: 2)
            if days.count >= 21 {
                Text(verbatim: Self.dateLabel(days[days.count / 2].day))
                Spacer(minLength: 2)
            }
            Text(verbatim: Self.dateLabel(days.last?.day))
        }
        .font(.system(size: 8.5).monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    // MARK: - Geometry

    private var barSpacing: CGFloat {
        switch days.count {
        case ...14: 4
        case ...30: 2
        case ...60: 1.5
        default: 1
        }
    }

    private func barHeight(for day: SupermuxDailyUsage, stats: Stats) -> CGFloat {
        guard stats.peak > 0 else { return Self.minBarHeight }
        let fraction = min(1, max(0, stats.value(of: day) / stats.peak))
        return max(Self.minBarHeight, CGFloat(fraction) * Self.plotHeight)
    }

    /// The peak day carries the strongest tint so the inline "peak" figure has
    /// a visible anchor without a hover readout.
    private func fill(for day: SupermuxDailyUsage, stats: Stats) -> Color {
        guard stats.value(of: day) > 0 else { return Color.primary.opacity(0.08) }
        return Color.accentColor.opacity(day.day == stats.peakDay ? 0.75 : 0.4)
    }

    // MARK: - Values

    /// Everything the bars need, derived once per body pass instead of once
    /// per bar.
    struct Stats {
        let metric: Metric
        let peak: Double
        let peakDay: Date?

        init(days: [SupermuxDailyUsage]) {
            let metric: Metric = days.contains { $0.cost.priced > 0 } ? .cost : .tokens
            self.metric = metric
            var peak = 0.0
            var peakDay: Date?
            for day in days {
                let value = Self.value(of: day, metric: metric)
                if value > peak {
                    peak = value
                    peakDay = day.day
                }
            }
            self.peak = peak
            self.peakDay = peakDay
        }

        func value(of day: SupermuxDailyUsage) -> Double {
            Self.value(of: day, metric: metric)
        }

        static func value(of day: SupermuxDailyUsage, metric: Metric) -> Double {
            switch metric {
            case .cost: day.cost.priced
            case .tokens: Double(day.tokens.total)
            }
        }
    }

    private static func valueText(_ value: Double, metric: Metric) -> String {
        switch metric {
        case .cost: SupermuxUsageAnalyticsFormat.currency(value)
        case .tokens: SupermuxUsageAnalyticsFormat.tokens(Int(value))
        }
    }

    private static func metricLabel(_ metric: Metric) -> String {
        switch metric {
        case .cost:
            String(localized: "supermux.analytics.chart.cost", defaultValue: "Daily cost")
        case .tokens:
            String(localized: "supermux.analytics.chart.tokens", defaultValue: "Daily tokens")
        }
    }

    private static func dateLabel(_ day: Date?) -> String {
        guard let day else { return "" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    private func accessibilityText(_ stats: Stats) -> String {
        guard let peakDay = stats.peakDay else {
            return String(
                format: String(
                    localized: "supermux.analytics.chart.accessibility.empty",
                    defaultValue: "%1$@ chart, %2$lld days, no usage"
                ),
                Self.metricLabel(stats.metric),
                days.count
            )
        }
        return String(
            format: String(
                localized: "supermux.analytics.chart.accessibility",
                defaultValue: "%1$@ chart, %2$lld days, peak %3$@ on %4$@"
            ),
            Self.metricLabel(stats.metric),
            days.count,
            Self.valueText(stats.peak, metric: stats.metric),
            peakDay.formatted(.dateTime.month(.abbreviated).day())
        )
    }
}

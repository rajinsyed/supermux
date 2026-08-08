public import Foundation
public import SwiftUI

/// Token spend over a rolling window, as the sidebar's second usage popover:
/// a headline "raw token cost", a daily strip, the provider split, and the
/// handful of models that account for it.
///
/// Purely presentational — every number comes from the passed report, and the
/// host owns scanning and range persistence.
public struct SupermuxUsageAnalyticsPopoverView: View {
    private let report: SupermuxUsageAnalyticsReport
    private let isScanning: Bool
    /// 0…1; only meaningful while ``isScanning``.
    private let scanProgress: Double
    /// Providers whose logs are absent entirely — named in the footer so an
    /// absent row reads as "not installed" rather than "no usage".
    private let missingProviders: Set<SupermuxAnalyticsProvider>
    private let generatedAt: Date?
    @Binding private var selectedRange: SupermuxAnalyticsRange
    private let onRefresh: () -> Void

    /// Whole turns completed by the refresh glyph; each scan start adds one,
    /// so the icon spins exactly once per scan and never snaps back.
    @State private var refreshTurns = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Models listed before the row collapses into a "+N more" count.
    private static let modelRowLimit = 3

    public init(
        report: SupermuxUsageAnalyticsReport,
        isScanning: Bool,
        scanProgress: Double,
        missingProviders: Set<SupermuxAnalyticsProvider>,
        generatedAt: Date?,
        selectedRange: Binding<SupermuxAnalyticsRange>,
        onRefresh: @escaping () -> Void
    ) {
        self.report = report
        self.isScanning = isScanning
        self.scanProgress = scanProgress
        self.missingProviders = missingProviders
        self.generatedAt = generatedAt
        self._selectedRange = selectedRange
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isScanning, !report.isEmpty {
                // Warm rescan over usable data: a hairline-thin progress line
                // instead of header text, which would squeeze the range pills.
                scanLine
                    .transition(.opacity)
            }
            if report.isEmpty {
                if isScanning {
                    coldScanBlock
                } else {
                    emptyBlock
                }
            } else {
                headline
                if report.daily.count > 1 {
                    SupermuxUsageAnalyticsChart(days: report.daily)
                }
                hairline
                providerSection
                if !modelRows.isEmpty {
                    hairline
                    modelSection
                }
            }
            footer
        }
        .padding(12)
        // Wider than the 264pt limits popover because a 90-day strip has to
        // stay legible; still narrow enough to read as a popover, not a window.
        .frame(width: 300, alignment: .leading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: report)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isScanning)
    }

    /// Section separator quieter than a full `Divider`.
    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(String(localized: "supermux.analytics.title", defaultValue: "Token Usage"))
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
            Spacer(minLength: 4)
            rangePicker
            refreshButton
        }
    }

    /// The warm-rescan hint: a 2pt accent line under the header, so already
    /// usable data stays put while the scan finishes.
    private var scanLine: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: max(2, proxy.size.width * clampedScanProgress))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: clampedScanProgress)
            }
        }
        .frame(height: 2)
        .padding(.top, -4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: String(localized: "supermux.analytics.scanning.short", defaultValue: "scanning %@"),
            SupermuxUsageAnalyticsFormat.percent(clampedScanProgress)
        ))
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(SupermuxAnalyticsRange.allCases) { range in
                rangePill(range)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "supermux.analytics.range.label", defaultValue: "Time range"))
    }

    private func rangePill(_ range: SupermuxAnalyticsRange) -> some View {
        let isSelected = range == selectedRange
        return Button {
            guard !isSelected else { return }
            if reduceMotion {
                selectedRange = range
            } else {
                withAnimation(.smooth(duration: 0.25)) { selectedRange = range }
            }
        } label: {
            Text(Self.compactRangeLabel(range))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.accentColor.opacity(isSelected ? 0.14 : 0))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(SupermuxPressEffectButtonStyle())
        .help(range.shortLabel)
        .accessibilityLabel(range.shortLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(isScanning ? 0.4 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isScanning)
                .rotationEffect(.degrees(Double(refreshTurns) * 360))
                // Keep the glyph small but give the click a 20pt target.
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(SupermuxPressEffectButtonStyle())
        .disabled(isScanning)
        .onChange(of: isScanning) { _, scanning in
            guard scanning, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7)) { refreshTurns += 1 }
        }
        .help(String(localized: "supermux.analytics.refresh", defaultValue: "Rescan usage logs"))
        .accessibilityLabel(String(localized: "supermux.analytics.refresh", defaultValue: "Rescan usage logs"))
    }

    // MARK: - Headline

    /// True when nothing in the range could be priced at all. The hero then
    /// shows tokens rather than a `$0.00` that would read as "spent nothing".
    private var isFullyUnpriced: Bool {
        report.cost.priced == 0 && report.cost.unpricedTokens > 0
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(isFullyUnpriced
                    ? String(localized: "supermux.analytics.tokens.eyebrow", defaultValue: "Tokens processed")
                    : String(localized: "supermux.analytics.cost.eyebrow", defaultValue: "Raw token cost"))
                    .font(.system(size: 8.5, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                if !isFullyUnpriced {
                    Text(String(
                        format: String(localized: "supermux.analytics.tokensTotal", defaultValue: "%@ tokens"),
                        SupermuxUsageAnalyticsFormat.tokens(report.tokens.total)
                    ))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            Text(verbatim: headlineValue)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .contentTransition(reduceMotion ? .identity : .numericText(value: report.cost.priced))
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: report.cost.priced)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(isFullyUnpriced
                ? String(
                    localized: "supermux.analytics.tokens.footnote",
                    defaultValue: "no list price known for these models"
                )
                : String(
                    localized: "supermux.analytics.cost.footnote",
                    defaultValue: "if billed at full API rates"
                ))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headlineAccessibilityText)
    }

    private var headlineValue: String {
        isFullyUnpriced
            ? SupermuxUsageAnalyticsFormat.tokens(report.tokens.total)
            : SupermuxUsageAnalyticsFormat.currency(report.cost.priced)
    }

    private var headlineAccessibilityText: String {
        if isFullyUnpriced {
            return String(
                format: String(
                    localized: "supermux.analytics.tokens.accessibility",
                    defaultValue: "%1$@ tokens over %2$@, no list price known"
                ),
                SupermuxUsageAnalyticsFormat.tokens(report.tokens.total),
                report.range.shortLabel
            )
        }
        return String(
            format: String(
                localized: "supermux.analytics.cost.accessibility",
                defaultValue: "%1$@ of raw token cost over %2$@, %3$@ tokens"
            ),
            SupermuxUsageAnalyticsFormat.currency(report.cost.priced),
            report.range.shortLabel,
            SupermuxUsageAnalyticsFormat.tokens(report.tokens.total)
        )
    }

    // MARK: - Providers

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            eyebrow(String(localized: "supermux.analytics.providers", defaultValue: "By agent"))
            ForEach(report.providers) { provider in
                SupermuxAnalyticsProviderRow(
                    usage: provider,
                    share: share(cost: provider.cost.priced, tokens: provider.tokens.total)
                )
            }
        }
    }

    // MARK: - Models

    private var modelRows: [SupermuxModelUsage] {
        Array(report.models.prefix(Self.modelRowLimit))
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            eyebrow(String(localized: "supermux.analytics.models", defaultValue: "Top models"))
            ForEach(modelRows) { model in
                modelRow(model)
            }
            if report.models.count > Self.modelRowLimit {
                Text(String(
                    format: String(localized: "supermux.analytics.models.more", defaultValue: "+%lld more"),
                    report.models.count - Self.modelRowLimit
                ))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func modelRow(_ model: SupermuxModelUsage) -> some View {
        HStack(spacing: 6) {
            Text(model.model)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: SupermuxUsageAnalyticsFormat.tokens(model.tokens.total))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(verbatim: model.isPriced
                ? SupermuxUsageAnalyticsFormat.currency(model.cost.priced)
                : String(localized: "supermux.analytics.unpriced.short", defaultValue: "unpriced"))
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(model.isPriced ? Color.primary.opacity(0.85) : Color.secondary)
            .frame(minWidth: 58, alignment: .trailing)
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: String(
                localized: "supermux.analytics.model.accessibility",
                defaultValue: "%1$@, %2$@, %3$@ tokens"
            ),
            model.model,
            model.isPriced
                ? SupermuxUsageAnalyticsFormat.currency(model.cost.priced)
                : String(localized: "supermux.analytics.unpriced.short", defaultValue: "unpriced"),
            SupermuxUsageAnalyticsFormat.tokens(model.tokens.total)
        ))
    }

    // MARK: - States

    /// Cold scan: determinate progress instead of a blank frame, because the
    /// first pass over a long history takes visibly longer than a refresh.
    private var coldScanBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Hand-rolled rather than `ProgressView(value:)`: the same quiet
            // track the provider meters use, so the loading frame and the
            // loaded frame are the same shape.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(3, proxy.size.width * clampedScanProgress))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: clampedScanProgress)
                }
            }
            .frame(height: 4)
            HStack(spacing: 6) {
                Text(String(localized: "supermux.analytics.scanning", defaultValue: "Reading usage logs…"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(verbatim: SupermuxUsageAnalyticsFormat.percent(clampedScanProgress))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: clampedScanProgress))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: clampedScanProgress)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: String(
                localized: "supermux.analytics.scanning.accessibility",
                defaultValue: "Reading usage logs, %@ complete"
            ),
            SupermuxUsageAnalyticsFormat.percent(clampedScanProgress)
        ))
    }

    private var clampedScanProgress: Double {
        min(1, max(0, scanProgress))
    }

    private var emptyBlock: some View {
        VStack(spacing: 4) {
            Image(systemName: allProvidersMissing ? "questionmark.folder" : "chart.bar.xaxis")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hint = emptyHint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var allProvidersMissing: Bool {
        missingProviders.count == SupermuxAnalyticsProvider.allCases.count
    }

    private var emptyTitle: String {
        allProvidersMissing
            ? String(
                localized: "supermux.analytics.empty.noLogs",
                defaultValue: "No Claude Code or Codex logs found"
            )
            : String(
                format: String(localized: "supermux.analytics.empty.range", defaultValue: "No usage in the last %@"),
                report.range.shortLabel
            )
    }

    private var emptyHint: String? {
        if allProvidersMissing {
            return String(
                localized: "supermux.analytics.empty.noLogs.hint",
                defaultValue: "Usage appears here after either agent runs."
            )
        }
        guard selectedRange != .quarter else { return nil }
        return String(
            localized: "supermux.analytics.empty.range.hint",
            defaultValue: "Try a longer range."
        )
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        let notes = footerNotes
        if !notes.isEmpty || generatedAt != nil {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let generatedAt {
                    Text(String(
                        format: String(localized: "supermux.analytics.scannedAt", defaultValue: "scanned %@"),
                        generatedAt.formatted(.relative(presentation: .named))
                    ))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Caveats that must never be silent: cache value, tokens nobody could
    /// price, and providers whose logs simply are not there.
    private var footerNotes: [String] {
        var notes: [String] = []
        if !report.isEmpty, report.cacheSavings > 0 {
            notes.append(String(
                format: String(
                    localized: "supermux.analytics.cacheSavings",
                    defaultValue: "caching saved %1$@ · %2$@ cache hits"
                ),
                SupermuxUsageAnalyticsFormat.currency(report.cacheSavings),
                SupermuxUsageAnalyticsFormat.percent(report.cacheHitRate)
            ))
        }
        // Only a caveat while a dollar total is on screen; when the hero is
        // already showing tokens with "no list price known", repeating that
        // those tokens are missing from a total there isn't reads as a bug.
        if report.cost.unpricedTokens > 0, !isFullyUnpriced {
            notes.append(String(
                format: String(
                    localized: "supermux.analytics.unpriced",
                    defaultValue: "%@ tokens from unrecognized models are not in the total"
                ),
                SupermuxUsageAnalyticsFormat.tokens(report.cost.unpricedTokens)
            ))
        }
        // Only worth saying while there is data to contrast it against; the
        // empty state already explains a fully absent setup.
        if !report.isEmpty {
            let missing = SupermuxAnalyticsProvider.allCases.filter(missingProviders.contains)
            for provider in missing {
                notes.append(String(
                    format: String(
                        localized: "supermux.analytics.missingProvider",
                        defaultValue: "no %@ logs found"
                    ),
                    provider.displayName
                ))
            }
        }
        return notes
    }

    // MARK: - Shared pieces

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    /// Share of the range, measured in dollars when anything was priced and in
    /// tokens when nothing was — a fully unpriced range still splits sensibly.
    private func share(cost: Double, tokens: Int) -> Double {
        if report.cost.priced > 0 {
            return cost / report.cost.priced
        }
        guard report.tokens.total > 0 else { return 0 }
        return Double(tokens) / Double(report.tokens.total)
    }

    private static func compactRangeLabel(_ range: SupermuxAnalyticsRange) -> String {
        switch range {
        case .week: String(localized: "supermux.analytics.range.week", defaultValue: "7d")
        case .month: String(localized: "supermux.analytics.range.month", defaultValue: "30d")
        case .quarter: String(localized: "supermux.analytics.range.quarter", defaultValue: "90d")
        }
    }
}

/// One agent's slice as a meter row — the fill behind the text carries the
/// share, so the popover never spends a line on a percent figure.
struct SupermuxAnalyticsProviderRow: View {
    let usage: SupermuxProviderUsage
    /// 0…1 share of the range.
    let share: Double

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: usage.provider.symbolName)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(usage.provider.displayName)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: SupermuxUsageAnalyticsFormat.tokens(usage.tokens.total))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(verbatim: costText)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isPriced ? Color.primary : Color.secondary)
                .contentTransition(reduceMotion ? .identity : .numericText(value: usage.cost.priced))
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: usage.cost.priced)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(meterFill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.smooth(duration: 0.55)) { hasAppeared = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: String(
                localized: "supermux.analytics.provider.accessibility",
                defaultValue: "%1$@, %2$@, %3$@ of the range, %4$@ tokens"
            ),
            usage.provider.displayName,
            costText,
            SupermuxUsageAnalyticsFormat.percent(share),
            SupermuxUsageAnalyticsFormat.tokens(usage.tokens.total)
        ))
    }

    /// An agent whose models are all unpriced says so instead of showing the
    /// `$0.00` its zeroed cost would otherwise render.
    private var isPriced: Bool {
        usage.cost.priced > 0 || usage.cost.unpricedTokens == 0
    }

    private var costText: String {
        isPriced
            ? SupermuxUsageAnalyticsFormat.currency(usage.cost.priced)
            : String(localized: "supermux.analytics.unpriced.short", defaultValue: "unpriced")
    }

    /// Quiet track with an accent fill proportional to the share; the tint
    /// stays under ~25% so the row's text keeps full contrast.
    private var meterFill: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                if clampedShare > 0 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: max(6, proxy.size.width * displayedShare))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: clampedShare)
                }
            }
        }
    }

    private var displayedShare: CGFloat {
        hasAppeared ? CGFloat(clampedShare) : 0
    }

    private var clampedShare: Double {
        min(1, max(0, share))
    }
}

/// Number formatting shared by the analytics popover and its chart.
enum SupermuxUsageAnalyticsFormat {
    /// USD list prices, always with cents so `$0.00` reads as a real zero
    /// rather than a missing value. The currency code is fixed because the
    /// rates are published in dollars; placement still follows the locale.
    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// Compact counts: `17.4B`, `360M`, `210K`, `842`. One fraction digit is
    /// kept only while the scaled value is under 100, where it still carries
    /// information.
    ///
    /// The unit is chosen against the *rounded* value, so 999,999 reads as
    /// `1M` rather than `1,000K`.
    static func tokens(_ count: Int) -> String {
        var value = Double(count)
        var unitIndex = -1
        // Promote on the *rounded* value, so 999,999 becomes "1M" instead of
        // the "1,000K" a raw magnitude test would produce.
        while unitIndex < Unit.ordered.count - 1, rounded(value, unitIndex: unitIndex) >= 1000 {
            value /= 1000
            unitIndex += 1
        }
        let number = value.formatted(
            .number.precision(.fractionLength(0...fractionDigits(for: value, unitIndex: unitIndex)))
        )
        guard unitIndex >= 0 else { return number }
        return String(format: Unit.ordered[unitIndex].pattern, number)
    }

    /// A 0…1 fraction as `66.7%` / `100%`.
    static func percent(_ fraction: Double) -> String {
        min(1, max(0, fraction)).formatted(.percent.precision(.fractionLength(0...1)))
    }

    /// Raw counts stay whole; scaled ones keep a decimal only below 100.
    private static func fractionDigits(for value: Double, unitIndex: Int) -> Int {
        unitIndex < 0 || abs(value) >= 100 ? 0 : 1
    }

    /// `value` as it will actually be displayed, for the promotion test.
    private static func rounded(_ value: Double, unitIndex: Int) -> Double {
        let scale = pow(10.0, Double(fractionDigits(for: value, unitIndex: unitIndex)))
        return (abs(value) * scale).rounded() / scale
    }

    private enum Unit {
        case thousands
        case millions
        case billions

        static let ordered: [Unit] = [.thousands, .millions, .billions]

        var pattern: String {
            switch self {
            case .thousands:
                String(localized: "supermux.analytics.tokens.thousands", defaultValue: "%@K")
            case .millions:
                String(localized: "supermux.analytics.tokens.millions", defaultValue: "%@M")
            case .billions:
                String(localized: "supermux.analytics.tokens.billions", defaultValue: "%@B")
            }
        }
    }
}

#if DEBUG

private func previewReport(
    range: SupermuxAnalyticsRange = .month,
    includeCodex: Bool = true,
    unpricedTokens: Int = 0
) -> SupermuxUsageAnalyticsReport {
    let calendar = Calendar.current
    let endDay = calendar.startOfDay(for: Date())
    let startDay = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: endDay) ?? endDay

    var daily: [SupermuxDailyUsage] = []
    for offset in 0..<range.dayCount {
        guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { break }
        let wave = (sin(Double(offset) * 0.7) + 1.3) * 40
        let idle = offset % 9 == 4
        let claude = idle ? 0 : wave * 3.1
        let codex = idle || !includeCodex ? 0 : wave * 1.4
        daily.append(SupermuxDailyUsage(
            day: day,
            tokens: SupermuxTokenCounts(
                uncachedInput: Int(claude * 900),
                cacheWrite: Int(claude * 2_400),
                cacheRead: Int(claude * 31_000),
                output: Int(claude * 700),
                reasoningOutput: Int(claude * 240)
            ),
            cost: SupermuxUsageCost(priced: claude + codex),
            costByProvider: includeCodex
                ? [.claudeCode: claude, .codex: codex]
                : [.claudeCode: claude],
            tokensByProvider: includeCodex
                ? [.claudeCode: Int(claude * 35_000), .codex: Int(codex * 21_000)]
                : [.claudeCode: Int(claude * 35_000)]
        ))
    }

    let claudeTokens = SupermuxTokenCounts(
        uncachedInput: 214_000_000,
        cacheWrite: 620_000_000,
        cacheRead: 9_100_000_000,
        output: 168_000_000,
        reasoningOutput: 61_000_000
    )
    let codexTokens = SupermuxTokenCounts(
        uncachedInput: 96_000_000,
        cacheWrite: 140_000_000,
        cacheRead: 3_050_000_000,
        output: 74_000_000,
        reasoningOutput: 39_000_000
    )
    var providers = [
        SupermuxProviderUsage(
            provider: .claudeCode,
            tokens: claudeTokens,
            cost: SupermuxUsageCost(priced: 10_536.12)
        ),
    ]
    var models = [
        SupermuxModelUsage(
            model: "claude-opus-5",
            provider: .claudeCode,
            tokens: claudeTokens,
            cost: SupermuxUsageCost(priced: 8_204.55)
        ),
        SupermuxModelUsage(
            model: "claude-sonnet-4-5-20250929",
            provider: .claudeCode,
            tokens: SupermuxTokenCounts(uncachedInput: 40_000_000, cacheRead: 810_000_000, output: 22_000_000),
            cost: SupermuxUsageCost(priced: 2_331.57)
        ),
    ]
    if includeCodex {
        providers.append(SupermuxProviderUsage(
            provider: .codex,
            tokens: codexTokens,
            cost: SupermuxUsageCost(priced: 5_258.63)
        ))
        models.append(SupermuxModelUsage(
            model: "gpt-5.6-sol",
            provider: .codex,
            tokens: codexTokens,
            cost: SupermuxUsageCost(priced: 5_258.63)
        ))
        models.append(SupermuxModelUsage(
            model: "gpt-5.4-mini",
            provider: .codex,
            tokens: SupermuxTokenCounts(uncachedInput: 9_000_000, output: 3_000_000),
            cost: SupermuxUsageCost(priced: 20.25)
        ))
    }
    if unpricedTokens > 0 {
        models.append(SupermuxModelUsage(
            model: "internal-preview-model",
            provider: .claudeCode,
            tokens: SupermuxTokenCounts(uncachedInput: unpricedTokens),
            cost: SupermuxUsageCost(unpricedTokens: unpricedTokens)
        ))
    }

    let totalTokens = includeCodex ? claudeTokens + codexTokens : claudeTokens
    return SupermuxUsageAnalyticsReport(
        range: range,
        startDay: startDay,
        endDay: endDay,
        tokens: totalTokens,
        cost: SupermuxUsageCost(
            priced: providers.reduce(0) { $0 + $1.cost.priced },
            unpricedTokens: unpricedTokens
        ),
        providers: providers,
        models: models,
        daily: daily,
        cacheSavings: 8_412.90
    )
}

/// Rich data, both providers, unpriced tokens present.
#Preview("Rich") {
    @Previewable @State var range: SupermuxAnalyticsRange = .month
    SupermuxUsageAnalyticsPopoverView(
        report: previewReport(range: range, unpricedTokens: 12_400_000),
        isScanning: false,
        scanProgress: 1,
        missingProviders: [],
        generatedAt: Date().addingTimeInterval(-320),
        selectedRange: $range,
        onRefresh: {}
    )
}

/// 90 days: the densest strip the chart has to stay legible at.
#Preview("Quarter") {
    @Previewable @State var range: SupermuxAnalyticsRange = .quarter
    SupermuxUsageAnalyticsPopoverView(
        report: previewReport(range: .quarter),
        isScanning: false,
        scanProgress: 1,
        missingProviders: [],
        generatedAt: Date().addingTimeInterval(-86_400),
        selectedRange: $range,
        onRefresh: {}
    )
}

/// Codex never ran: its row is absent and the footer says why.
#Preview("Provider missing") {
    @Previewable @State var range: SupermuxAnalyticsRange = .week
    SupermuxUsageAnalyticsPopoverView(
        report: previewReport(range: .week, includeCodex: false),
        isScanning: false,
        scanProgress: 1,
        missingProviders: [.codex],
        generatedAt: Date().addingTimeInterval(-45),
        selectedRange: $range,
        onRefresh: {}
    )
}

/// Cold scan: progress instead of a blank frame.
#Preview("Cold scan") {
    @Previewable @State var range: SupermuxAnalyticsRange = .month
    SupermuxUsageAnalyticsPopoverView(
        report: .empty(range: .month),
        isScanning: true,
        scanProgress: 0.42,
        missingProviders: [],
        generatedAt: nil,
        selectedRange: $range,
        onRefresh: {}
    )
}

/// Warm rescan over existing data.
#Preview("Rescanning") {
    @Previewable @State var range: SupermuxAnalyticsRange = .week
    SupermuxUsageAnalyticsPopoverView(
        report: previewReport(range: .week),
        isScanning: true,
        scanProgress: 0.66,
        missingProviders: [],
        generatedAt: Date().addingTimeInterval(-900),
        selectedRange: $range,
        onRefresh: {}
    )
}

/// Nothing in the range could be priced: the hero shows tokens, never $0.00.
#Preview("All unpriced") {
    @Previewable @State var range: SupermuxAnalyticsRange = .week
    let tokens = SupermuxTokenCounts(uncachedInput: 41_000_000, cacheRead: 260_000_000, output: 12_000_000)
    let calendar = Calendar.current
    let endDay = calendar.startOfDay(for: Date())
    let startDay = calendar.date(byAdding: .day, value: -6, to: endDay) ?? endDay
    let daily = (0..<7).compactMap { offset -> SupermuxDailyUsage? in
        guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
        let scale = offset % 3 == 0 ? 2 : 1
        return SupermuxDailyUsage(
            day: day,
            tokens: SupermuxTokenCounts(uncachedInput: 6_000_000 * scale, output: 1_700_000 * scale),
            cost: SupermuxUsageCost(unpricedTokens: 7_700_000 * scale),
            costByProvider: [:],
            tokensByProvider: [.claudeCode: 7_700_000 * scale]
        )
    }
    SupermuxUsageAnalyticsPopoverView(
        report: SupermuxUsageAnalyticsReport(
            range: .week,
            startDay: startDay,
            endDay: endDay,
            tokens: tokens,
            cost: SupermuxUsageCost(unpricedTokens: tokens.total),
            providers: [
                SupermuxProviderUsage(
                    provider: .claudeCode,
                    tokens: tokens,
                    cost: SupermuxUsageCost(unpricedTokens: tokens.total)
                ),
            ],
            models: [
                SupermuxModelUsage(
                    model: "internal-preview-model",
                    provider: .claudeCode,
                    tokens: tokens,
                    cost: SupermuxUsageCost(unpricedTokens: tokens.total)
                ),
            ],
            daily: daily,
            cacheSavings: 0
        ),
        isScanning: false,
        scanProgress: 1,
        missingProviders: [.codex],
        generatedAt: Date(),
        selectedRange: $range,
        onRefresh: {}
    )
}

/// Usage exists, just not in this window.
#Preview("Empty range") {
    @Previewable @State var range: SupermuxAnalyticsRange = .week
    SupermuxUsageAnalyticsPopoverView(
        report: .empty(range: .week),
        isScanning: false,
        scanProgress: 1,
        missingProviders: [],
        generatedAt: Date().addingTimeInterval(-60),
        selectedRange: $range,
        onRefresh: {}
    )
}

/// Neither agent installed.
#Preview("No logs") {
    @Previewable @State var range: SupermuxAnalyticsRange = .month
    SupermuxUsageAnalyticsPopoverView(
        report: .empty(range: .month),
        isScanning: false,
        scanProgress: 1,
        missingProviders: Set(SupermuxAnalyticsProvider.allCases),
        generatedAt: Date(),
        selectedRange: $range,
        onRefresh: {}
    )
}

#endif

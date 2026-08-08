public import Foundation

/// One model's slice of a report.
public struct SupermuxModelUsage: Sendable, Equatable, Identifiable {
    public var model: String
    public var provider: SupermuxAnalyticsProvider
    public var tokens: SupermuxTokenCounts
    public var cost: SupermuxUsageCost

    public var id: String { "\(provider.rawValue):\(model)" }

    /// Whether this model's tokens could be priced at all.
    public var isPriced: Bool { cost.unpricedTokens == 0 }

    public init(
        model: String,
        provider: SupermuxAnalyticsProvider,
        tokens: SupermuxTokenCounts,
        cost: SupermuxUsageCost
    ) {
        self.model = model
        self.provider = provider
        self.tokens = tokens
        self.cost = cost
    }
}

/// One provider's slice of a report.
public struct SupermuxProviderUsage: Sendable, Equatable, Identifiable {
    public var provider: SupermuxAnalyticsProvider
    public var tokens: SupermuxTokenCounts
    public var cost: SupermuxUsageCost

    public var id: SupermuxAnalyticsProvider { provider }

    public init(provider: SupermuxAnalyticsProvider, tokens: SupermuxTokenCounts, cost: SupermuxUsageCost) {
        self.provider = provider
        self.tokens = tokens
        self.cost = cost
    }
}

/// One local day, split by provider so the chart can stack them.
public struct SupermuxDailyUsage: Sendable, Equatable, Identifiable {
    public var day: Date
    public var tokens: SupermuxTokenCounts
    public var cost: SupermuxUsageCost
    /// Per-provider cost for the stacked area chart. Providers with no usage
    /// that day are present with zero so the chart has no gaps.
    public var costByProvider: [SupermuxAnalyticsProvider: Double]
    public var tokensByProvider: [SupermuxAnalyticsProvider: Int]

    public var id: Date { day }

    public init(
        day: Date,
        tokens: SupermuxTokenCounts,
        cost: SupermuxUsageCost,
        costByProvider: [SupermuxAnalyticsProvider: Double],
        tokensByProvider: [SupermuxAnalyticsProvider: Int]
    ) {
        self.day = day
        self.tokens = tokens
        self.cost = cost
        self.costByProvider = costByProvider
        self.tokensByProvider = tokensByProvider
    }
}

/// Everything the popover renders for one selected range — computed purely
/// from a snapshot so it is trivially testable and cheap to recompute when the
/// user flips ranges.
public struct SupermuxUsageAnalyticsReport: Sendable, Equatable {
    public var range: SupermuxAnalyticsRange
    /// First and last local day the report covers (inclusive).
    public var startDay: Date
    public var endDay: Date
    public var tokens: SupermuxTokenCounts
    public var cost: SupermuxUsageCost
    public var providers: [SupermuxProviderUsage]
    public var models: [SupermuxModelUsage]
    public var daily: [SupermuxDailyUsage]
    /// Dollars saved by cache reads versus paying full input rate.
    public var cacheSavings: Double

    public init(
        range: SupermuxAnalyticsRange,
        startDay: Date,
        endDay: Date,
        tokens: SupermuxTokenCounts,
        cost: SupermuxUsageCost,
        providers: [SupermuxProviderUsage],
        models: [SupermuxModelUsage],
        daily: [SupermuxDailyUsage],
        cacheSavings: Double
    ) {
        self.range = range
        self.startDay = startDay
        self.endDay = endDay
        self.tokens = tokens
        self.cost = cost
        self.providers = providers
        self.models = models
        self.daily = daily
        self.cacheSavings = cacheSavings
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// Days in the range that saw any usage — the denominator for "per active
    /// day" figures, which are misleading when averaged over idle days.
    public var activeDayCount: Int {
        daily.count { !$0.tokens.isEmpty }
    }

    /// Share of observed prompt tokens that were served from cache.
    public var cacheHitRate: Double {
        guard tokens.observedInput > 0 else { return 0 }
        return Double(tokens.cacheRead) / Double(tokens.observedInput)
    }

    /// The largest single-day cost, for scaling the chart's y-axis.
    public var peakDailyCost: Double {
        daily.map(\.cost.priced).max() ?? 0
    }

    public static func empty(range: SupermuxAnalyticsRange) -> Self {
        let today = Calendar.current.startOfDay(for: Date())
        return Self(
            range: range,
            startDay: today,
            endDay: today,
            tokens: .zero,
            cost: .zero,
            providers: [],
            models: [],
            daily: [],
            cacheSavings: 0
        )
    }
}

public enum SupermuxUsageAnalyticsAggregator {
    /// Collapses a snapshot into the report for `range`, ending today.
    ///
    /// Days are local-calendar days; the range is inclusive of today and of
    /// `range.dayCount - 1` days before it. Every day in the window appears in
    /// `daily`, including empty ones, so the chart's x-axis is continuous.
    public static func report(
        from snapshot: SupermuxUsageAnalyticsSnapshot,
        range: SupermuxAnalyticsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SupermuxUsageAnalyticsReport {
        let endDay = calendar.startOfDay(for: now)
        guard let startDay = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: endDay) else {
            return .empty(range: range)
        }

        // Filter on the same normalized day the bucket is keyed by. The
        // scanners emit local midnights, but a snapshot built under a different
        // calendar (or a DST shift) can carry a mid-day instant, which would
        // pass a raw `<= endDay` test and then key a bucket outside the window
        // that the `daily` walk never visits — silently losing today's usage.
        let entries = snapshot.entries.compactMap { entry -> (day: Date, entry: SupermuxUsageAnalyticsEntry)? in
            let day = calendar.startOfDay(for: entry.day)
            guard day >= startDay, day <= endDay else { return nil }
            return (day, entry)
        }

        var totalTokens = SupermuxTokenCounts.zero
        var totalCost = SupermuxUsageCost.zero
        var cacheSavings = 0.0
        var byProvider: [SupermuxAnalyticsProvider: (SupermuxTokenCounts, SupermuxUsageCost)] = [:]
        var byModel: [String: SupermuxModelUsage] = [:]
        var byDay: [Date: (SupermuxTokenCounts, SupermuxUsageCost, [SupermuxAnalyticsProvider: Double], [SupermuxAnalyticsProvider: Int])] = [:]

        for (dayKey, entry) in entries {
            let priced = SupermuxModelPricing.priced(entry.tokens, model: entry.model)
            let cost = priced.cost
            totalTokens += entry.tokens
            totalCost += cost
            cacheSavings += priced.cacheSavings

            var provider = byProvider[entry.provider] ?? (.zero, .zero)
            provider.0 += entry.tokens
            provider.1 += cost
            byProvider[entry.provider] = provider

            let modelKey = "\(entry.provider.rawValue):\(entry.model)"
            if var existing = byModel[modelKey] {
                existing.tokens += entry.tokens
                existing.cost += cost
                byModel[modelKey] = existing
            } else {
                byModel[modelKey] = SupermuxModelUsage(
                    model: entry.model,
                    provider: entry.provider,
                    tokens: entry.tokens,
                    cost: cost
                )
            }

            var day = byDay[dayKey] ?? (.zero, .zero, [:], [:])
            day.0 += entry.tokens
            day.1 += cost
            day.2[entry.provider, default: 0] += cost.priced
            day.3[entry.provider, default: 0] += entry.tokens.total
            byDay[dayKey] = day
        }

        var daily: [SupermuxDailyUsage] = []
        var cursor = startDay
        while cursor <= endDay {
            let bucket = byDay[cursor] ?? (.zero, .zero, [:], [:])
            daily.append(SupermuxDailyUsage(
                day: cursor,
                tokens: bucket.0,
                cost: bucket.1,
                costByProvider: bucket.2,
                tokensByProvider: bucket.3
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            // Re-normalize: in zones whose DST transition deletes midnight the
            // added day lands at 01:00, which would no longer match a bucket
            // key and would drop that day's bars.
            cursor = calendar.startOfDay(for: next)
        }

        let providers = byProvider
            .map { SupermuxProviderUsage(provider: $0.key, tokens: $0.value.0, cost: $0.value.1) }
            .sorted { lhs, rhs in
                if lhs.cost.priced != rhs.cost.priced { return lhs.cost.priced > rhs.cost.priced }
                return lhs.provider < rhs.provider
            }

        // Cost descending, then tokens — an unpriced model with real traffic
        // still needs to rank above a priced model with none.
        let models = byModel.values.sorted { lhs, rhs in
            if lhs.cost.priced != rhs.cost.priced { return lhs.cost.priced > rhs.cost.priced }
            if lhs.tokens.total != rhs.tokens.total { return lhs.tokens.total > rhs.tokens.total }
            return lhs.model < rhs.model
        }

        return SupermuxUsageAnalyticsReport(
            range: range,
            startDay: startDay,
            endDay: endDay,
            tokens: totalTokens,
            cost: totalCost,
            providers: providers,
            models: models,
            daily: daily,
            cacheSavings: cacheSavings
        )
    }
}

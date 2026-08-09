import Foundation
import Testing

@testable import SupermuxKit

@Suite struct SupermuxModelPricingTests {
    @Test func normalizesHarnessDecorations() {
        #expect(SupermuxModelPricing.normalize("claude-fable-5[1m]") == "claude-fable-5")
        #expect(SupermuxModelPricing.normalize("anthropic.claude-opus-5") == "claude-opus-5")
        #expect(SupermuxModelPricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(SupermuxModelPricing.normalize("GPT-5.6-Sol") == "gpt-5.6-sol")
        #expect(SupermuxModelPricing.normalize("gpt-5.2:latest") == "gpt-5.2")
    }

    /// A snapshot suffix must not be mistaken for a version segment — the
    /// 8-digit rule only strips trailing dates.
    @Test func keepsVersionSegmentsThatAreNotDates() {
        #expect(SupermuxModelPricing.normalize("claude-opus-4-8") == "claude-opus-4-8")
        #expect(SupermuxModelPricing.rate(for: "claude-opus-4-8")?.input == 5)
    }

    @Test func pricesAnthropicCacheTiersFromTheInputRate() throws {
        let rate = try #require(SupermuxModelPricing.rate(for: "claude-fable-5"))
        #expect(rate.input == 10)
        #expect(rate.output == 50)
        #expect(rate.cacheRead == 1)
        #expect(rate.cacheWrite == 12.5)
    }

    /// GPT-5.2-generation models bill cache creation at the plain input rate;
    /// only the 5.6 family carries a write premium.
    @Test func appliesWritePremiumOnlyToNewerOpenAIModels() throws {
        let codex = try #require(SupermuxModelPricing.rate(for: "gpt-5.2-codex"))
        #expect(codex.cacheWrite == codex.input)
        let sol = try #require(SupermuxModelPricing.rate(for: "gpt-5.6-sol"))
        #expect(sol.cacheWrite == sol.input * 1.25)
    }

    /// Routing prefixes nest. A single ordered pass stripped `anthropic.` first
    /// and left `us.` in front, which missed both the exact table and the
    /// family fallback and dropped a real Bedrock model into the unpriced
    /// bucket.
    @Test func stripsNestedRoutingPrefixes() throws {
        #expect(SupermuxModelPricing.normalize("us.anthropic.claude-opus-5") == "claude-opus-5")
        #expect(SupermuxModelPricing.normalize("bedrock/us.anthropic.claude-sonnet-5") == "claude-sonnet-5")
        #expect(try #require(SupermuxModelPricing.rate(for: "us.anthropic.claude-opus-5")).input == 5)
    }

    /// Cost and cache savings must agree with the one-shot lookup the
    /// aggregator uses, or the footer's savings figure drifts from the total.
    @Test func combinedPricingMatchesTheIndividualEntryPoints() {
        let tokens = SupermuxTokenCounts(
            uncachedInput: 1_000_000,
            cacheWrite: 500_000,
            cacheRead: 4_000_000,
            output: 250_000
        )
        for model in ["claude-fable-5", "gpt-5.2-codex", "some-future-model-9", "<synthetic>"] {
            let combined = SupermuxModelPricing.priced(tokens, model: model)
            #expect(combined.cost == SupermuxModelPricing.cost(of: tokens, model: model))
            #expect(combined.cacheSavings == SupermuxModelPricing.cacheSavings(of: tokens, model: model))
        }
    }

    @Test func fallsBackToFamilyRateForUnknownPointReleases() throws {
        let rate = try #require(SupermuxModelPricing.rate(for: "claude-opus-5-3"))
        #expect(rate.input == 5)
        #expect(rate.output == 25)
    }

    @Test func computesCostAcrossAllFourTokenClasses() {
        let tokens = SupermuxTokenCounts(
            uncachedInput: 1_000_000,
            cacheWrite: 1_000_000,
            cacheRead: 1_000_000,
            output: 1_000_000
        )
        let cost = SupermuxModelPricing.cost(of: tokens, model: "claude-fable-5")
        #expect(abs(cost.priced - (10 + 12.5 + 1 + 50)) < 0.0001)
        #expect(cost.unpricedTokens == 0)
    }

    /// An unknown model must never read as free spend — its tokens surface in
    /// the unpriced bucket so the UI can footnote them.
    @Test func reportsUnknownModelsAsUnpricedRatherThanFree() {
        let tokens = SupermuxTokenCounts(uncachedInput: 500, output: 500)
        let cost = SupermuxModelPricing.cost(of: tokens, model: "some-future-model-9")
        #expect(cost.priced == 0)
        #expect(cost.unpricedTokens == 1000)
    }

    @Test func skipsSyntheticPlaceholderEntries() {
        #expect(SupermuxModelPricing.isSynthetic("<synthetic>"))
        let cost = SupermuxModelPricing.cost(
            of: SupermuxTokenCounts(uncachedInput: 100),
            model: "<synthetic>"
        )
        #expect(cost == .zero)
    }

    @Test func measuresCacheSavingsAgainstTheFullInputRate() {
        let tokens = SupermuxTokenCounts(cacheRead: 1_000_000)
        let savings = SupermuxModelPricing.cacheSavings(of: tokens, model: "claude-fable-5")
        #expect(abs(savings - 9) < 0.0001)
    }
}

@Suite struct SupermuxUsageAnalyticsAggregatorTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! #require(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    @Test func keepsEveryDayInRangeSoTheChartHasNoGaps() {
        let snapshot = SupermuxUsageAnalyticsSnapshot(entries: [
            .init(day: day(-2, from: now), provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(output: 1000)),
        ])
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .week, now: now, calendar: calendar
        )
        #expect(report.daily.count == 7)
        #expect(report.daily.filter { $0.tokens.isEmpty }.count == 6)
        #expect(report.activeDayCount == 1)
    }

    @Test func excludesEntriesOutsideTheSelectedRange() {
        let snapshot = SupermuxUsageAnalyticsSnapshot(entries: [
            .init(day: day(-3, from: now), provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(output: 100)),
            .init(day: day(-40, from: now), provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(output: 900)),
        ])
        let week = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .week, now: now, calendar: calendar
        )
        #expect(week.tokens.output == 100)
        let quarter = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .quarter, now: now, calendar: calendar
        )
        #expect(quarter.tokens.output == 1000)
    }

    @Test func mergesRepeatedModelsAndRanksByCost() {
        let today = day(0, from: now)
        let snapshot = SupermuxUsageAnalyticsSnapshot(entries: [
            .init(day: today, provider: .claudeCode, model: "claude-haiku-4-5",
                  tokens: SupermuxTokenCounts(output: 1_000_000)),
            .init(day: today, provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(output: 100_000)),
            .init(day: today, provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(output: 100_000)),
        ])
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .week, now: now, calendar: calendar
        )
        #expect(report.models.count == 2)
        // Fable's 200K output at $50/M outranks Haiku's 1M at $5/M.
        #expect(report.models.first?.model == "claude-fable-5")
        #expect(report.models.first?.tokens.output == 200_000)
    }

    /// The same model id from two providers stays separate — a Codex-routed
    /// model must not be folded into the Claude Code row.
    @Test func keepsIdenticalModelIdsSeparatePerProvider() {
        let today = day(0, from: now)
        let snapshot = SupermuxUsageAnalyticsSnapshot(entries: [
            .init(day: today, provider: .claudeCode, model: "gpt-5.6-sol",
                  tokens: SupermuxTokenCounts(output: 1000)),
            .init(day: today, provider: .codex, model: "gpt-5.6-sol",
                  tokens: SupermuxTokenCounts(output: 1000)),
        ])
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .week, now: now, calendar: calendar
        )
        #expect(report.models.count == 2)
        #expect(report.providers.count == 2)
    }

    @Test func splitsDailyCostByProviderForTheStackedChart() {
        let today = day(0, from: now)
        let snapshot = SupermuxUsageAnalyticsSnapshot(entries: [
            .init(day: today, provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(output: 1_000_000)),
            .init(day: today, provider: .codex, model: "gpt-5.6-sol",
                  tokens: SupermuxTokenCounts(output: 1_000_000)),
        ])
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .week, now: now, calendar: calendar
        )
        let last = report.daily.last!
        #expect(abs((last.costByProvider[.claudeCode] ?? 0) - 50) < 0.0001)
        #expect(abs((last.costByProvider[.codex] ?? 0) - 30) < 0.0001)
        #expect(abs(last.cost.priced - 80) < 0.0001)
    }

    @Test func computesCacheHitRateOverPromptTokensOnly() {
        let snapshot = SupermuxUsageAnalyticsSnapshot(entries: [
            .init(day: day(0, from: now), provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(
                      uncachedInput: 100, cacheWrite: 100, cacheRead: 800, output: 5000
                  )),
        ])
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .week, now: now, calendar: calendar
        )
        // Output tokens must not dilute the rate: 800 / (100+100+800).
        #expect(abs(report.cacheHitRate - 0.8) < 0.0001)
    }

    /// Entries carrying a mid-day instant (a snapshot built under a different
    /// calendar, or a cache written before a timezone change) used to pass the
    /// raw `<= endDay` filter and then key a bucket the `daily` walk never
    /// visits — the tokens counted toward the total but no bar ever showed
    /// them, and an entry later than `endDay`'s midnight vanished entirely.
    @Test func normalizesEntryDaysBeforeFilteringAndBucketing() {
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))!
        let snapshot = SupermuxUsageAnalyticsSnapshot(entries: [
            .init(day: noon, provider: .claudeCode, model: "claude-fable-5",
                  tokens: SupermuxTokenCounts(output: 1_000_000)),
        ])
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: snapshot, range: .week, now: now, calendar: calendar
        )
        #expect(report.tokens.output == 1_000_000)
        // The tokens must land on a real bar, not in a bucket off the axis.
        #expect(report.activeDayCount == 1)
        #expect(report.daily.last?.tokens.output == 1_000_000)
        #expect(abs(report.peakDailyCost - 50) < 0.0001)
    }

    /// Every day the walk emits must be a normalized local midnight, so bucket
    /// keys and axis days cannot disagree.
    @Test func everyDailyBucketIsALocalMidnight() {
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: .empty, range: .quarter, now: now, calendar: calendar
        )
        #expect(report.daily.count == 90)
        #expect(report.daily.allSatisfy { $0.day == calendar.startOfDay(for: $0.day) })
        #expect(Set(report.daily.map(\.day)).count == 90)
    }

    @Test func emptySnapshotProducesAnEmptyButWellFormedReport() {
        let report = SupermuxUsageAnalyticsAggregator.report(
            from: .empty, range: .month, now: now, calendar: calendar
        )
        #expect(report.isEmpty)
        #expect(report.daily.count == 30)
        #expect(report.activeDayCount == 0)
        #expect(report.peakDailyCost == 0)
    }
}

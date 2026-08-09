public import Foundation

/// Which coding agent produced a slice of usage.
public enum SupermuxAnalyticsProvider: String, Sendable, Codable, CaseIterable, Comparable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode:
            String(localized: "supermux.analytics.provider.claudeCode", defaultValue: "Claude Code")
        case .codex:
            String(localized: "supermux.analytics.provider.codex", defaultValue: "Codex")
        }
    }

    /// SF Symbol standing in for the provider in dense rows.
    public var symbolName: String {
        switch self {
        case .claudeCode: "asterisk"
        case .codex: "circle.hexagongrid"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Token counts normalized across both providers.
///
/// The providers disagree on what `input` means — Claude Code's
/// `input_tokens` excludes cached reads and cache writes, while Codex's
/// `input_tokens` is the *whole* prompt with `cached_input_tokens` as a subset.
/// Both are normalized here so `uncachedInput`, `cacheWrite` and `cacheRead`
/// never overlap and always sum to the billed prompt size.
public struct SupermuxTokenCounts: Sendable, Codable, Equatable, Hashable {
    /// Prompt tokens billed at the full input rate.
    public var uncachedInput: Int
    /// Prompt tokens written into the cache (billed at a premium).
    public var cacheWrite: Int
    /// Prompt tokens served from cache (billed at ~10% of input).
    public var cacheRead: Int
    /// Completion tokens, including reasoning/thinking tokens.
    public var output: Int
    /// Reasoning tokens — a *subset* of ``output``, tracked only so the UI can
    /// annotate how much of the output was thinking. Never billed separately.
    public var reasoningOutput: Int

    public init(
        uncachedInput: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoningOutput: Int = 0
    ) {
        self.uncachedInput = uncachedInput
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    public static let zero = SupermuxTokenCounts()

    /// Every token the API processed for these requests.
    public var total: Int { uncachedInput + cacheWrite + cacheRead + output }

    /// Prompt tokens only — what a "cache hit rate" is measured against.
    public var observedInput: Int { uncachedInput + cacheWrite + cacheRead }

    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: Self, rhs: Self) -> Self {
        SupermuxTokenCounts(
            uncachedInput: lhs.uncachedInput + rhs.uncachedInput,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output,
            reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput
        )
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}

/// One provider's usage of one model on one local calendar day — the atom the
/// scanners emit and everything else aggregates.
public struct SupermuxUsageAnalyticsEntry: Sendable, Codable, Equatable {
    /// Local midnight of the day the requests happened.
    public var day: Date
    public var provider: SupermuxAnalyticsProvider
    /// Raw model id as the logs recorded it (normalized only for pricing).
    public var model: String
    public var tokens: SupermuxTokenCounts

    public init(
        day: Date,
        provider: SupermuxAnalyticsProvider,
        model: String,
        tokens: SupermuxTokenCounts
    ) {
        self.day = day
        self.provider = provider
        self.model = model
        self.tokens = tokens
    }
}

/// Everything the scanners found, before any range is applied.
///
/// A cold scan publishes several of these as it works (`isComplete == false`)
/// so the popover fills in instead of spinning on an empty frame.
public struct SupermuxUsageAnalyticsSnapshot: Sendable, Equatable {
    public var entries: [SupermuxUsageAnalyticsEntry]
    /// When this scan pass ran.
    public var generatedAt: Date
    /// False while a scan is still walking files.
    public var isComplete: Bool
    public var scannedFileCount: Int
    public var totalFileCount: Int
    /// Providers whose logs are absent entirely (never installed / never run).
    public var missingProviders: Set<SupermuxAnalyticsProvider>

    public init(
        entries: [SupermuxUsageAnalyticsEntry] = [],
        generatedAt: Date = Date(),
        isComplete: Bool = true,
        scannedFileCount: Int = 0,
        totalFileCount: Int = 0,
        missingProviders: Set<SupermuxAnalyticsProvider> = []
    ) {
        self.entries = entries
        self.generatedAt = generatedAt
        self.isComplete = isComplete
        self.scannedFileCount = scannedFileCount
        self.totalFileCount = totalFileCount
        self.missingProviders = missingProviders
    }

    /// 0…1 progress of a cold scan; 1 once complete.
    public var scanProgress: Double {
        guard !isComplete, totalFileCount > 0 else { return 1 }
        return min(1, Double(scannedFileCount) / Double(totalFileCount))
    }

    public static let empty = SupermuxUsageAnalyticsSnapshot()
}

/// The windows the popover offers, mirroring what the logs can honestly cover.
public enum SupermuxAnalyticsRange: Int, Sendable, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    public var id: Int { rawValue }
    public var dayCount: Int { rawValue }

    public var shortLabel: String {
        String(
            format: String(localized: "supermux.analytics.range.days", defaultValue: "%lld days"),
            dayCount
        )
    }
}

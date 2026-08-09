import Foundation

/// Per-million-token rates for one model, in USD.
public struct SupermuxModelRate: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// Anthropic's uniform cache multipliers: reads 0.1×, 5-minute writes
    /// 1.25× (Claude Code always uses the 5-minute TTL).
    static func anthropic(input: Double, output: Double) -> Self {
        Self(input: input, output: output, cacheRead: input * 0.1, cacheWrite: input * 1.25)
    }

    /// GPT-5.6 generation: reads 0.1×, writes 1.25×.
    static func openAICaching(input: Double, output: Double) -> Self {
        Self(input: input, output: output, cacheRead: input * 0.1, cacheWrite: input * 1.25)
    }

    /// GPT-5.2/5.3/5.4/5.5 generation: reads 0.1×, cache creation billed at
    /// the plain input rate (no write premium).
    static func openAINoWritePremium(input: Double, output: Double) -> Self {
        Self(input: input, output: output, cacheRead: input * 0.1, cacheWrite: input)
    }
}

/// What a cost figure is worth: list-priced, or tokens we could not price.
public struct SupermuxUsageCost: Sendable, Equatable {
    public var priced: Double
    /// Tokens belonging to models with no known rate — surfaced instead of
    /// being silently counted as free.
    public var unpricedTokens: Int

    public init(priced: Double = 0, unpricedTokens: Int = 0) {
        self.priced = priced
        self.unpricedTokens = unpricedTokens
    }

    public static let zero = SupermuxUsageCost()

    public static func + (lhs: Self, rhs: Self) -> Self {
        SupermuxUsageCost(
            priced: lhs.priced + rhs.priced,
            unpricedTokens: lhs.unpricedTokens + rhs.unpricedTokens
        )
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}

/// List API prices for the models Claude Code and Codex actually emit.
///
/// The number this produces is "what these tokens would have cost at full API
/// rates" — subscription plans (Claude Max, ChatGPT Pro) bill nothing per
/// token, so the figure is a value estimate, not an invoice. Rates are list
/// prices as of August 2026; unknown ids are reported as unpriced rather than
/// guessed, so a new model shows up as a visible gap instead of a silent zero.
public enum SupermuxModelPricing {
    /// Exact-match table, keyed by normalized model id.
    static let rates: [String: SupermuxModelRate] = [
        // Anthropic — Opus tier.
        "claude-opus-5": .anthropic(input: 5, output: 25),
        "claude-opus-4-8": .anthropic(input: 5, output: 25),
        "claude-opus-4-7": .anthropic(input: 5, output: 25),
        "claude-opus-4-6": .anthropic(input: 5, output: 25),
        "claude-opus-4-5": .anthropic(input: 5, output: 25),
        "claude-opus-4-1": .anthropic(input: 15, output: 75),
        "claude-opus-4": .anthropic(input: 15, output: 75),
        // Anthropic — Mythos tier.
        "claude-fable-5": .anthropic(input: 10, output: 50),
        "claude-mythos-5": .anthropic(input: 10, output: 50),
        // Anthropic — Sonnet tier.
        "claude-sonnet-5": .anthropic(input: 3, output: 15),
        "claude-sonnet-4-6": .anthropic(input: 3, output: 15),
        "claude-sonnet-4-5": .anthropic(input: 3, output: 15),
        "claude-sonnet-4": .anthropic(input: 3, output: 15),
        "claude-3-7-sonnet": .anthropic(input: 3, output: 15),
        // Anthropic — Haiku tier.
        "claude-haiku-4-5": .anthropic(input: 1, output: 5),
        "claude-3-5-haiku": .anthropic(input: 0.8, output: 4),
        // OpenAI — GPT-5.6 generation (cache writes billed at 1.25×).
        "gpt-5.6": .openAICaching(input: 5, output: 30),
        "gpt-5.6-sol": .openAICaching(input: 5, output: 30),
        "gpt-5.6-terra": .openAICaching(input: 2.5, output: 15),
        "gpt-5.6-luna": .openAICaching(input: 1, output: 6),
        // OpenAI — earlier GPT-5.x generations (no cache-write premium).
        "gpt-5.5": .openAINoWritePremium(input: 5, output: 30),
        "gpt-5.4": .openAINoWritePremium(input: 2.5, output: 15),
        "gpt-5.4-mini": .openAINoWritePremium(input: 0.75, output: 4.5),
        "gpt-5.4-nano": .openAINoWritePremium(input: 0.2, output: 1.25),
        "gpt-5.3-codex": .openAINoWritePremium(input: 1.75, output: 14),
        "gpt-5.2-codex": .openAINoWritePremium(input: 1.75, output: 14),
        "gpt-5.2": .openAINoWritePremium(input: 1.75, output: 14),
        "gpt-5-codex": .openAINoWritePremium(input: 1.25, output: 10),
        "gpt-5": .openAINoWritePremium(input: 1.25, output: 10),
    ]

    /// Family fallbacks applied when an exact id misses — a new point release
    /// (`claude-opus-5-1`, `gpt-5.7-sol`) prices at its family's rate rather
    /// than dropping into the unpriced bucket. Longest prefix wins.
    static let familyPrefixes: [(prefix: String, rate: SupermuxModelRate)] = [
        ("claude-opus", .anthropic(input: 5, output: 25)),
        ("claude-fable", .anthropic(input: 10, output: 50)),
        ("claude-mythos", .anthropic(input: 10, output: 50)),
        ("claude-sonnet", .anthropic(input: 3, output: 15)),
        ("claude-haiku", .anthropic(input: 1, output: 5)),
        ("gpt-5.6", .openAICaching(input: 5, output: 30)),
    ]

    /// Provider/gateway decorations stripped off the front of a model id. They
    /// nest, so ``normalize(_:)`` peels repeatedly rather than once.
    static let routingPrefixes = ["us.", "eu.", "apac.", "anthropic.", "openai.", "bedrock/", "vertex/"]

    /// Strips the decorations harnesses add to a model id: provider prefixes
    /// (`anthropic.claude-opus-5`), context-window suffixes (`[1m]`), version
    /// tags (`:latest`), and trailing snapshot dates (`-20251001`).
    public static func normalize(_ model: String) -> String {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let bracket = id.firstIndex(of: "[") {
            id = String(id[id.startIndex..<bracket])
        }
        if let colon = id.firstIndex(of: ":") {
            id = String(id[id.startIndex..<colon])
        }
        // Routed ids stack their decorations (`bedrock/us.anthropic.claude-…`),
        // so strip until nothing matches. A single ordered pass would leave the
        // inner prefix behind whenever the outer one sorts later in the list,
        // and the leftover `us.` defeated even the family fallback.
        var didStrip = true
        while didStrip {
            didStrip = false
            for prefix in Self.routingPrefixes where id.hasPrefix(prefix) {
                id = String(id.dropFirst(prefix.count))
                didStrip = true
                break
            }
        }
        // Trailing 8-digit snapshot date: claude-haiku-4-5-20251001.
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            id = parts.dropLast().joined(separator: "-")
        }
        return id
    }

    /// The rate for a model id, or `nil` when nothing in the table matches.
    public static func rate(for model: String) -> SupermuxModelRate? {
        rate(forNormalized: normalize(model))
    }

    /// `rate(for:)` on an id that is already normalized — the hot path, so the
    /// longest-prefix search walks the table instead of allocating a filtered
    /// copy of it per lookup.
    private static func rate(forNormalized id: String) -> SupermuxModelRate? {
        if let exact = rates[id] { return exact }
        var best: (length: Int, rate: SupermuxModelRate)?
        for candidate in familyPrefixes where id.hasPrefix(candidate.prefix) {
            if best == nil || candidate.prefix.count > best!.length {
                best = (candidate.prefix.count, candidate.rate)
            }
        }
        return best?.rate
    }

    /// Whether a model id is a CLI placeholder rather than a real API call.
    /// Claude Code writes `<synthetic>` entries for interrupts and local
    /// errors; they carry zero usage and never cost anything.
    public static func isSynthetic(_ model: String) -> Bool {
        isSyntheticNormalized(normalize(model))
    }

    private static func isSyntheticNormalized(_ id: String) -> Bool {
        id.isEmpty || id == "<synthetic>" || id == "synthetic"
    }

    /// Cost of `tokens` at `model`'s list rate. Unknown models contribute no
    /// dollars and report their tokens as unpriced.
    public static func cost(of tokens: SupermuxTokenCounts, model: String) -> SupermuxUsageCost {
        priced(tokens, model: model).cost
    }

    /// What the cached reads would have cost at the full input rate minus what
    /// they actually cost — the "cache savings" headline.
    public static func cacheSavings(of tokens: SupermuxTokenCounts, model: String) -> Double {
        priced(tokens, model: model).cacheSavings
    }

    /// Cost and cache savings from one rate lookup.
    ///
    /// The aggregator needs both figures for every entry; resolving them
    /// separately normalized the same id four times per entry, which is the
    /// whole per-entry cost over a 90-day range.
    public static func priced(
        _ tokens: SupermuxTokenCounts,
        model: String
    ) -> (cost: SupermuxUsageCost, cacheSavings: Double) {
        let id = normalize(model)
        guard !isSyntheticNormalized(id) else { return (.zero, 0) }
        guard let rate = rate(forNormalized: id) else {
            return (SupermuxUsageCost(unpricedTokens: tokens.total), 0)
        }
        let millions = 1_000_000.0
        let priced = Double(tokens.uncachedInput) / millions * rate.input
            + Double(tokens.cacheWrite) / millions * rate.cacheWrite
            + Double(tokens.cacheRead) / millions * rate.cacheRead
            + Double(tokens.output) / millions * rate.output
        let savings = Double(tokens.cacheRead) / millions * (rate.input - rate.cacheRead)
        return (SupermuxUsageCost(priced: priced), savings)
    }
}

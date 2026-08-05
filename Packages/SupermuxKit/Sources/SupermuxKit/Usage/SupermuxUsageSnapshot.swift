public import Foundation

/// One provider rate-limit window (Claude's 5-hour/7-day, Codex's 5-hour/weekly,
/// or a scoped/per-model weekly limit) as rendered by the usage tracker.
public struct SupermuxUsageWindow: Sendable, Equatable {
    /// Which window this is, driving the row label and sort order.
    public enum Kind: Sendable, Equatable {
        /// The rolling ~5-hour session window.
        case session
        /// The rolling 7-day window across all models.
        case weekly
        /// A scoped weekly limit (per model/feature), labeled by the provider
        /// (e.g. "Fable", "GPT-5.3-Codex-Spark").
        case scoped(String)
    }

    public let kind: Kind
    /// Utilization percent, 0–100 (clamped for rendering).
    public let percent: Double
    /// When the window resets, when the provider reported it.
    public let resetsAt: Date?

    public init(kind: Kind, percent: Double, resetsAt: Date?) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// Severity bucket for coloring bars and the footer gauge.
    public var severity: SupermuxUsageSeverity {
        SupermuxUsageSeverity(percent: percent)
    }
}

/// Shared coloring thresholds for usage bars and the footer gauge.
public enum SupermuxUsageSeverity: Sendable, Equatable, Comparable {
    case normal
    case warning
    case critical

    public init(percent: Double) {
        switch percent {
        case ..<70: self = .normal
        case ..<90: self = .warning
        default: self = .critical
        }
    }
}

/// Claude usage for one account (cswap manages several; the direct fallback
/// yields exactly one).
public struct SupermuxClaudeAccountUsage: Sendable, Equatable, Identifiable {
    /// How usable this account's data is. Mirrors cswap's `usageStatus`
    /// sentinels; the direct fallback maps into the same cases.
    public enum Status: Sendable, Equatable {
        /// Usage data present and decision-grade.
        case ok
        /// The stored token expired; Claude Code refreshes it on next use.
        case tokenExpired
        /// A re-login is needed before usage can be fetched again.
        case reloginRequired
        /// No usage available right now (fetch failed, keychain locked, …);
        /// `windows` may still carry last-good data when the source had any.
        case unavailable(reason: String?)
    }

    /// Stable per-row identity. cswap's parser tolerates malformed rows, so
    /// `email` alone could collide on `""`; the slot number disambiguates.
    public var id: String { "\(slot.map(String.init) ?? "-")|\(email)" }
    /// cswap slot number (`nil` for the direct-API single account).
    public let slot: Int?
    public let email: String
    /// Display alias/organization when it reads better than the raw email.
    public let displayName: String?
    /// Whether this is the account Claude Code is currently logged in as.
    public let isActive: Bool
    /// Held out of cswap's rotation (`cswap disable`); still switchable-to
    /// explicitly, but rendered dimmed.
    public let isDisabled: Bool
    public let status: Status
    /// Session + weekly + scoped windows, in render order.
    public let windows: [SupermuxUsageWindow]
    /// When the underlying measurement was fetched (cswap serves cached data).
    public let fetchedAt: Date?

    public init(
        slot: Int? = nil,
        email: String,
        displayName: String?,
        isActive: Bool,
        isDisabled: Bool = false,
        status: Status,
        windows: [SupermuxUsageWindow],
        fetchedAt: Date?
    ) {
        self.slot = slot
        self.email = email
        self.displayName = displayName
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.status = status
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

/// A full Claude-side snapshot: every known account, active one first.
public struct SupermuxClaudeUsageSnapshot: Sendable, Equatable {
    /// Where the data came from, shown as a footnote and used to pick refresh
    /// cadence (cswap enforces its own API politeness; the direct path must
    /// self-throttle).
    public enum Source: Sendable, Equatable {
        case cswap
        case directAPI
    }

    public let source: Source
    public let accounts: [SupermuxClaudeAccountUsage]
    public let fetchedAt: Date

    public init(source: Source, accounts: [SupermuxClaudeAccountUsage], fetchedAt: Date) {
        self.source = source
        self.accounts = accounts
        self.fetchedAt = fetchedAt
    }

    /// The account whose limits gate the user's current Claude Code session.
    public var activeAccount: SupermuxClaudeAccountUsage? {
        accounts.first(where: \.isActive) ?? accounts.first
    }
}

/// Codex (ChatGPT-subscription) usage snapshot.
public struct SupermuxCodexUsageSnapshot: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Live response from the ChatGPT usage endpoint.
        case api
        /// Parsed from the newest local Codex session log (may be stale).
        case sessionLog
    }

    public let source: Source
    /// e.g. "pro", "plus". Raw provider string, capitalized at render time.
    public let planType: String?
    public let windows: [SupermuxUsageWindow]
    public let fetchedAt: Date

    public init(source: Source, planType: String?, windows: [SupermuxUsageWindow], fetchedAt: Date) {
        self.source = source
        self.planType = planType
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

/// Terminal states for one provider column in the tracker.
public enum SupermuxUsageProviderState<Snapshot: Sendable & Equatable>: Sendable, Equatable {
    /// Nothing fetched yet (first poll in flight).
    case loading
    /// The provider's CLI isn't installed / has never logged in here.
    case notConfigured
    /// Credentials exist but are unusable until the user re-authenticates.
    case needsLogin(detail: String?)
    /// A fetch failed and nothing cached is available.
    case failed(message: String)
    /// Usable data (possibly served from cache; check the snapshot's age).
    case ready(Snapshot)

    public var snapshot: Snapshot? {
        if case .ready(let snapshot) = self { return snapshot }
        return nil
    }
}

extension SupermuxUsageWindow.Kind {
    /// Stable ordering for rendering: session, weekly, then scoped by name.
    var sortRank: Int {
        switch self {
        case .session: 0
        case .weekly: 1
        case .scoped: 2
        }
    }
}

extension [SupermuxUsageWindow] {
    /// The single most constrained window — what the footer gauge shows.
    public var tightest: SupermuxUsageWindow? {
        self.max { $0.percent < $1.percent }
    }

    /// Windows in canonical render order (session, weekly, scoped).
    public func sortedForDisplay() -> [SupermuxUsageWindow] {
        sorted { lhs, rhs in
            if lhs.kind.sortRank != rhs.kind.sortRank {
                return lhs.kind.sortRank < rhs.kind.sortRank
            }
            return lhs.percent > rhs.percent
        }
    }
}

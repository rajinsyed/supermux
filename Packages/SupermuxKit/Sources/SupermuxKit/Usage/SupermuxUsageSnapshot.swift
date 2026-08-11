public import Foundation
// SupermuxUsageSeverity and SupermuxUsageCountdown live in the shared wire
// package so the iOS usage screen buckets percents and formats resets exactly
// like the desktop popover does.
//
// This is a source break for anything that imported ONLY SupermuxKit and
// named those types unqualified: `public import` lets them appear in this
// module's public signatures, but does not put them back in a client's
// unqualified scope. Harmless today — SupermuxKit is fork-internal, consumed
// only by the cmux app target — but a future extractor of this package must
// import SupermuxMobileCore alongside it.
public import SupermuxMobileCore

/// One provider rate-limit window (Claude's 5-hour/7-day, Codex's 5-hour/weekly,
/// or a scoped/per-model weekly limit) as rendered by the usage tracker.
public struct SupermuxUsageWindow: Sendable, Equatable {
    /// Which window this is, driving the row label and sort order. Hashable
    /// so a window's kind can serve as its SwiftUI identity — a row must not
    /// morph into a different window when the set changes order or length.
    public enum Kind: Sendable, Equatable, Hashable {
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
    /// cswap's linear pace verdict for weekly windows: `true` when usage is
    /// meaningfully ahead of the elapsed fraction of the window (you'd run
    /// out before reset at this rate). `nil` when the source computes no pace
    /// (5h windows, Codex, direct API, or early in a fresh window).
    public let aheadOfPace: Bool?

    public init(kind: Kind, percent: Double, resetsAt: Date?, aheadOfPace: Bool? = nil) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.aheadOfPace = aheadOfPace
    }

    /// Severity bucket for coloring bars and the footer gauge.
    public var severity: SupermuxUsageSeverity {
        SupermuxUsageSeverity(percent: percent)
    }
}

/// A provider snapshot carrying its own measurement time, so the model can
/// refuse to replace newer displayed data with an older fallback snapshot.
public protocol SupermuxTimestampedUsageSnapshot: Sendable, Equatable {
    var fetchedAt: Date { get }
    /// When the newest data in this snapshot was actually MEASURED. Defaults
    /// to `fetchedAt`; sources whose parse time says nothing about data age
    /// (cswap serves cached measurements) override it.
    var measuredAt: Date { get }
}

extension SupermuxTimestampedUsageSnapshot {
    public var measuredAt: Date { fetchedAt }
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
    /// `email` alone could collide on `""`; the slot number disambiguates,
    /// and the source-row ordinal covers rows missing both slot and email.
    public var id: String { "\(slot.map(String.init) ?? "#\(ordinal)")|\(email)" }
    /// cswap slot number (`nil` for the direct-API single account).
    public let slot: Int?
    /// Position of this row in the source payload; only used to keep the
    /// identity unique when both `slot` and `email` are absent.
    public let ordinal: Int
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
        ordinal: Int = 0,
        email: String,
        displayName: String?,
        isActive: Bool,
        isDisabled: Bool = false,
        status: Status,
        windows: [SupermuxUsageWindow],
        fetchedAt: Date?
    ) {
        self.slot = slot
        self.ordinal = ordinal
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
public struct SupermuxClaudeUsageSnapshot: SupermuxTimestampedUsageSnapshot {
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

    /// The ACTIVE account's measurement time, not the parse time: a degraded
    /// cswap pass serving only `lastGoodUsage` must compare as OLD so it
    /// never overwrites fresher data on display — and a freshly-measured
    /// SECONDARY account must not vouch for a stale active one, since the
    /// active account is what drives the gauge and the primary rows.
    /// Falls back to the parse time when the active row carries no timestamp
    /// (cswap payloads without fetched-at fields).
    public var measuredAt: Date {
        activeAccount?.fetchedAt ?? fetchedAt
    }
}

/// Codex (ChatGPT-subscription) usage snapshot.
public struct SupermuxCodexUsageSnapshot: SupermuxTimestampedUsageSnapshot {
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
    /// `true` when this snapshot was served from the session log BECAUSE the
    /// stored credential is expired/rejected — the data renders, but the user
    /// needs to know live refresh is broken until they sign in again.
    public let needsRelogin: Bool

    public init(
        source: Source,
        planType: String?,
        windows: [SupermuxUsageWindow],
        fetchedAt: Date,
        needsRelogin: Bool = false
    ) {
        self.source = source
        self.planType = planType
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.needsRelogin = needsRelogin
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

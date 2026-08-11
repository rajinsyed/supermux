public import Foundation

/// Wire representation of the usage tracker (`mobile.supermux.usage.state`):
/// the Claude Code and Codex rate-limit windows the Mac's sidebar gauge shows,
/// mirrored read-only onto the phone.
///
/// Enum-ish fields travel as plain strings with typed accessors, so a newer
/// Mac adding a provider state or account status degrades to the neutral case
/// on an older phone instead of failing the whole decode.

/// One provider rate-limit window (Claude's 5-hour/7-day, Codex's
/// 5-hour/weekly, or a scoped per-model weekly limit).
public struct SupermuxUsageWindowDTO: Codable, Sendable, Equatable {
    /// Which window this is: `"session"`, `"weekly"`, or `"scoped"`.
    public var kind: String
    /// The provider's label for a `scoped` window (e.g. "Fable"); absent for
    /// the session and weekly windows, which the phone labels itself.
    public var label: String?
    /// Utilization percent, 0–100 (clamped at render time).
    public var percent: Double
    /// When the window resets, Unix seconds.
    public var resetsAt: Double?
    /// cswap's linear pace verdict for weekly windows: `true` when usage is
    /// meaningfully ahead of the elapsed fraction of the window. Absent when
    /// the source computes no pace.
    public var aheadOfPace: Bool?

    /// The `session` window's wire kind.
    public static let sessionKind = "session"
    /// The `weekly` window's wire kind.
    public static let weeklyKind = "weekly"
    /// The `scoped` (per-model/feature) window's wire kind.
    public static let scopedKind = "scoped"

    /// Creates a window row.
    /// - Parameters:
    ///   - kind: The window's wire kind.
    ///   - label: The provider's label for scoped windows.
    ///   - percent: Utilization percent, 0–100.
    ///   - resetsAt: Reset time in Unix seconds.
    ///   - aheadOfPace: cswap's pace verdict, when computed.
    public init(
        kind: String,
        label: String? = nil,
        percent: Double,
        resetsAt: Double? = nil,
        aheadOfPace: Bool? = nil
    ) {
        self.kind = kind
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.aheadOfPace = aheadOfPace
    }

    /// The percent clamped into 0–100 for rendering.
    public var clampedPercent: Double {
        min(100, max(0, percent))
    }

    /// The severity bucket driving this window's color.
    public var severity: SupermuxUsageSeverity {
        SupermuxUsageSeverity(percent: clampedPercent)
    }

    /// The reset time as a `Date`, when the provider reported one.
    public var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: $0) }
    }

    /// Stable ordering for rendering: session, weekly, then scoped.
    public var sortRank: Int {
        switch kind {
        case Self.sessionKind: 0
        case Self.weeklyKind: 1
        default: 2
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case label
        case percent
        case resetsAt = "resets_at"
        case aheadOfPace = "ahead_of_pace"
    }
}

extension [SupermuxUsageWindowDTO] {
    /// The single most constrained window — what a gauge shows.
    public var tightest: SupermuxUsageWindowDTO? {
        self.max { $0.percent < $1.percent }
    }

    /// Windows in canonical render order (session, weekly, then scoped).
    public func sortedForDisplay() -> [SupermuxUsageWindowDTO] {
        sorted { lhs, rhs in
            if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
            return lhs.percent > rhs.percent
        }
    }
}

/// Claude usage for one account (cswap manages several; the direct-API
/// fallback yields exactly one).
public struct SupermuxUsageAccountDTO: Codable, Sendable, Equatable, Identifiable {
    /// Stable per-row identity, assigned Mac-side (slot-or-ordinal + email),
    /// since a malformed cswap row can carry neither a slot nor an email.
    public var id: String
    /// cswap slot number; absent for the direct-API single account.
    public var slot: Int?
    /// The account's email, when the source reported one.
    public var email: String?
    /// Display alias/organization when it reads better than the raw email.
    public var displayName: String?
    /// Whether Claude Code is currently logged in as this account.
    public var isActive: Bool?
    /// Held out of cswap's rotation (`cswap disable`).
    public var isDisabled: Bool?
    /// How usable this account's data is: `"ok"`, `"token_expired"`,
    /// `"relogin_required"`, or `"unavailable"`.
    public var status: String?
    /// cswap's raw reason sentinel for an `unavailable` status
    /// (e.g. `"keychain_unavailable"`), when it reported one.
    public var statusDetail: String?
    /// Session + weekly + scoped windows. May be last-good data when the
    /// status is not `ok`.
    public var windows: [SupermuxUsageWindowDTO]?
    /// When this account's numbers were measured, Unix seconds (cswap serves
    /// cached measurements, so this is not the fetch time).
    public var fetchedAt: Double?

    /// The healthy account status's wire string.
    public static let okStatus = "ok"

    /// Creates an account row.
    /// - Parameters:
    ///   - id: Mac-assigned stable row identity.
    ///   - slot: cswap slot number, when any.
    ///   - email: The account email.
    ///   - displayName: A friendlier alias, when any.
    ///   - isActive: Whether this is the logged-in account.
    ///   - isDisabled: Whether the account is held out of rotation.
    ///   - status: The account status wire string.
    ///   - statusDetail: cswap's raw unavailable reason.
    ///   - windows: The account's limit windows.
    ///   - fetchedAt: Measurement time in Unix seconds.
    public init(
        id: String,
        slot: Int? = nil,
        email: String? = nil,
        displayName: String? = nil,
        isActive: Bool? = nil,
        isDisabled: Bool? = nil,
        status: String? = nil,
        statusDetail: String? = nil,
        windows: [SupermuxUsageWindowDTO]? = nil,
        fetchedAt: Double? = nil
    ) {
        self.id = id
        self.slot = slot
        self.email = email
        self.displayName = displayName
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.status = status
        self.statusDetail = statusDetail
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    /// The account's limit windows, never `nil` for the caller.
    public var displayWindows: [SupermuxUsageWindowDTO] { windows ?? [] }

    /// Whether the account's credentials are healthy (an absent status is
    /// treated as healthy, so an older Mac's leaner payload still renders).
    public var isHealthy: Bool { (status ?? Self.okStatus) == Self.okStatus }

    private enum CodingKeys: String, CodingKey {
        case id
        case slot
        case email
        case displayName = "display_name"
        case isActive = "is_active"
        case isDisabled = "is_disabled"
        case status
        case statusDetail = "status_detail"
        case windows
        case fetchedAt = "fetched_at"
    }
}

/// One provider column of the tracker (Claude Code or Codex) with its
/// terminal state, so the phone renders the same "not configured" / "sign in
/// again" / error notes the Mac popover does.
public struct SupermuxUsageProviderDTO: Codable, Sendable, Equatable {
    /// The provider's state: `"loading"`, `"not_configured"`,
    /// `"needs_login"`, `"failed"`, or `"ready"`.
    public var state: String
    /// The failure text for a `failed` state.
    public var message: String?
    /// Where the data came from — Claude: `"cswap"` / `"direct_api"`;
    /// Codex: `"api"` / `"session_log"`.
    public var source: String?
    /// Claude only: every known account, active first.
    public var accounts: [SupermuxUsageAccountDTO]?
    /// Codex only: the plan string (e.g. `"pro"`), capitalized at render time.
    public var planType: String?
    /// Codex only: this snapshot rendered from the local session log BECAUSE
    /// the stored credential is expired/rejected.
    public var needsRelogin: Bool?
    /// Codex only: its windows (Claude's live on the account rows).
    public var windows: [SupermuxUsageWindowDTO]?
    /// When the snapshot was fetched, Unix seconds.
    public var fetchedAt: Double?

    /// Nothing fetched yet.
    public static let loadingState = "loading"
    /// The provider's CLI isn't installed / has never logged in here.
    public static let notConfiguredState = "not_configured"
    /// Credentials exist but need re-authentication.
    public static let needsLoginState = "needs_login"
    /// A fetch failed and nothing cached was available.
    public static let failedState = "failed"
    /// Usable data.
    public static let readyState = "ready"
    /// Claude's cswap source string.
    public static let cswapSource = "cswap"
    /// Codex's local-session-log source string.
    public static let sessionLogSource = "session_log"

    /// Creates a provider column.
    /// - Parameters:
    ///   - state: The provider state wire string.
    ///   - message: The failure text, for `failed`.
    ///   - source: The data source wire string.
    ///   - accounts: Claude's account rows.
    ///   - planType: Codex's plan string.
    ///   - needsRelogin: Codex's expired-credential marker.
    ///   - windows: Codex's limit windows.
    ///   - fetchedAt: Fetch time in Unix seconds.
    public init(
        state: String,
        message: String? = nil,
        source: String? = nil,
        accounts: [SupermuxUsageAccountDTO]? = nil,
        planType: String? = nil,
        needsRelogin: Bool? = nil,
        windows: [SupermuxUsageWindowDTO]? = nil,
        fetchedAt: Double? = nil
    ) {
        self.state = state
        self.message = message
        self.source = source
        self.accounts = accounts
        self.planType = planType
        self.needsRelogin = needsRelogin
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    /// The account whose limits gate the current Claude Code session.
    public var activeAccount: SupermuxUsageAccountDTO? {
        let rows = accounts ?? []
        return rows.first { $0.isActive == true } ?? rows.first
    }

    /// The windows this provider contributes to a combined gauge: Claude's
    /// active account, or Codex's own list.
    public var gaugeWindows: [SupermuxUsageWindowDTO] {
        guard state == Self.readyState else { return [] }
        if let windows { return windows }
        return activeAccount?.displayWindows ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case message
        case source
        case accounts
        case planType = "plan_type"
        case needsRelogin = "needs_relogin"
        case windows
        case fetchedAt = "fetched_at"
    }
}

/// The `mobile.supermux.usage.state` result: both provider columns as the
/// Mac's shared usage model currently holds them.
public struct SupermuxUsageStateDTO: Codable, Sendable, Equatable {
    /// The Claude Code column.
    public var claude: SupermuxUsageProviderDTO
    /// The Codex column.
    public var codex: SupermuxUsageProviderDTO

    /// Creates the state payload.
    /// - Parameters:
    ///   - claude: The Claude Code column.
    ///   - codex: The Codex column.
    public init(claude: SupermuxUsageProviderDTO, codex: SupermuxUsageProviderDTO) {
        self.claude = claude
        self.codex = codex
    }

    /// The single most constrained window across both providers — what the
    /// phone's toolbar gauge fills to. `nil` until something is ready.
    public var tightestWindow: SupermuxUsageWindowDTO? {
        (claude.gaugeWindows + codex.gaugeWindows).tightest
    }

    /// When the OLDEST data on display was measured — the honest
    /// "data 2 minutes ago" footer. Uses Claude's per-account measurement
    /// times, since cswap serves cached numbers whose fetch time says nothing
    /// about their age.
    public var oldestMeasurementDate: Date? {
        var stamps: [Double] = []
        if claude.state == SupermuxUsageProviderDTO.readyState {
            let accountStamps = (claude.accounts ?? []).compactMap(\.fetchedAt)
            if let oldest = accountStamps.min() {
                stamps.append(oldest)
            } else if let fetchedAt = claude.fetchedAt {
                stamps.append(fetchedAt)
            }
        }
        if codex.state == SupermuxUsageProviderDTO.readyState, let fetchedAt = codex.fetchedAt {
            stamps.append(fetchedAt)
        }
        return stamps.min().map { Date(timeIntervalSince1970: $0) }
    }
}

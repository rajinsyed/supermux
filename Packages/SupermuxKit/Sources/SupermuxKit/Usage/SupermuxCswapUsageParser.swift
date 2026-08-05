import Foundation

/// Parses `cswap list --json` (claude-swap schema v1) into the tracker's
/// Claude snapshot.
///
/// cswap is the preferred Claude source: it manages multiple accounts, serves
/// usage from a shared on-disk cache with its own politeness policy against
/// Anthropic's tightly-budgeted usage endpoint (~28-30 requests/hour/token),
/// so the tracker never spends that budget itself while cswap is installed.
///
/// The parser is deliberately lenient: unknown fields are ignored, malformed
/// account rows degrade to `.unavailable` instead of failing the snapshot, and
/// `lastGoodUsage` backfills windows when live `usage` is null.
enum SupermuxCswapUsageParser {
    /// The one schema major this parser understands.
    static let supportedSchemaVersion = 1

    /// Decodes the `cswap list --json` payload. Returns `nil` when the data is
    /// not the expected schema (schemaVersion missing or not v1).
    static func parse(jsonData: Data, now: Date = Date()) -> SupermuxClaudeUsageSnapshot? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: jsonData) else { return nil }
        guard payload.schemaVersion == supportedSchemaVersion else { return nil }
        // Rows decode lossily and individually: one malformed row must not
        // discard the other accounts (it degrades to an unavailable stub).
        let accounts = payload.accounts.enumerated().map { index, row in
            account(from: row.value, ordinal: index)
        }
        // Active account first, then cswap's slot order.
        let ordered = accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return false
        }
        return SupermuxClaudeUsageSnapshot(source: .cswap, accounts: ordered, fetchedAt: now)
    }

    private static func account(from row: Payload.Account?, ordinal: Int) -> SupermuxClaudeAccountUsage {
        guard let row else {
            return SupermuxClaudeAccountUsage(
                ordinal: ordinal,
                email: "",
                displayName: nil,
                isActive: false,
                status: .unavailable(reason: nil),
                windows: [],
                fetchedAt: nil
            )
        }
        let usage = row.usage ?? row.lastGoodUsage
        let windows = usage.map(windows(from:)) ?? []
        let fetchedAt = (row.usageFetchedAt ?? row.lastGoodFetchedAt)
            .flatMap(Self.parseISODate)
        return SupermuxClaudeAccountUsage(
            slot: row.number,
            ordinal: ordinal,
            email: row.email ?? "",
            displayName: displayName(for: row),
            isActive: row.active ?? false,
            isDisabled: row.disabled ?? false,
            status: status(for: row),
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private static func displayName(for row: Payload.Account) -> String? {
        if let alias = row.alias, !alias.isEmpty { return alias }
        // Organization names like "user@host's Organization" add nothing over
        // the email; only surface a real name.
        if let org = row.organizationName, !org.isEmpty,
           let email = row.email, !org.contains(email) {
            return org
        }
        return nil
    }

    private static func status(for row: Payload.Account) -> SupermuxClaudeAccountUsage.Status {
        switch row.usageStatus {
        case "ok": return .ok
        case "token_expired": return .tokenExpired
        case "relogin_required": return .reloginRequired
        case nil: return row.usage != nil ? .ok : .unavailable(reason: nil)
        case let other?: return .unavailable(reason: other)
        }
    }

    private static func windows(from usage: Payload.Usage) -> [SupermuxUsageWindow] {
        var windows: [SupermuxUsageWindow] = []
        // A window with no reported percentage is dropped, never rendered as
        // 0% — "no quota used" and "unknown" must stay distinguishable.
        if let window = usage.fiveHour, let pct = SupermuxUsagePercent.normalized(window.pct) {
            windows.append(SupermuxUsageWindow(
                kind: .session,
                percent: pct,
                resetsAt: window.resetsAt.flatMap(Self.parseISODate)
            ))
        }
        if let window = usage.sevenDay, let pct = SupermuxUsagePercent.normalized(window.pct) {
            windows.append(SupermuxUsageWindow(
                kind: .weekly,
                percent: pct,
                resetsAt: window.resetsAt.flatMap(Self.parseISODate),
                aheadOfPace: window.aheadOfPace
            ))
        }
        for scoped in usage.scoped ?? [] {
            guard let name = scoped.name, !name.isEmpty,
                  let pct = SupermuxUsagePercent.normalized(scoped.pct) else { continue }
            windows.append(SupermuxUsageWindow(
                kind: .scoped(name),
                percent: pct,
                resetsAt: scoped.resetsAt.flatMap(Self.parseISODate),
                aheadOfPace: scoped.aheadOfPace
            ))
        }
        return windows
    }

    /// cswap emits ISO 8601 with fractional seconds and offsets
    /// (`2026-08-04T19:30:00.880114+00:00`) and plain `Z`-suffixed stamps.
    static func parseISODate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - Wire types (lenient: everything optional)

    private struct Payload: Decodable {
        let schemaVersion: Int
        let accounts: [LossyAccount]

        struct Account: Decodable {
            let number: Int?
            let email: String?
            let alias: String?
            let organizationName: String?
            let active: Bool?
            let disabled: Bool?
            let usageStatus: String?
            let usage: Usage?
            let lastGoodUsage: Usage?
            let usageFetchedAt: String?
            let lastGoodFetchedAt: String?
        }

        struct Usage: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?
            let scoped: [ScopedWindow]?
        }

        struct Window: Decodable {
            let pct: Double?
            let resetsAt: String?
            let aheadOfPace: Bool?
        }

        struct ScopedWindow: Decodable {
            let pct: Double?
            let resetsAt: String?
            let name: String?
            let aheadOfPace: Bool?
        }
    }

    /// Decodes one account row, swallowing per-row type mismatches so a
    /// single malformed row degrades to a stub instead of failing the list.
    private struct LossyAccount: Decodable {
        let value: Payload.Account?
        init(from decoder: any Decoder) {
            value = try? Payload.Account(from: decoder)
        }
    }
}

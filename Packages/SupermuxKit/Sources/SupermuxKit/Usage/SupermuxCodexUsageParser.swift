import Foundation

/// Parses OpenAI Codex usage data from either of its two shapes:
/// the ChatGPT usage endpoint (`/backend-api/wham/usage`) and the
/// `rate_limits` events Codex writes into local session rollout logs.
///
/// Window identification MUST key off the window length, not the
/// primary/secondary position: when one limit is binding the server can
/// return only that window as `primary_window` (observed live: a weekly
/// window at 86% served as primary with `secondary_window: null`).
enum SupermuxCodexUsageParser {
    /// Scoped pools excluded from display (lowercased `limit_name`s).
    /// Currently just the promotional Codex Spark pool.
    static let hiddenScopedLimitNames: Set<String> = ["gpt-5.3-codex-spark"]

    /// Seconds in the ~5-hour session window (REST: `limit_window_seconds`).
    private static let sessionWindowSeconds = 18000.0
    /// The session window in minutes (session logs: `window_minutes`).
    private static let sessionWindowMinutes = 300.0

    // MARK: - REST endpoint response

    /// Decodes a `/backend-api/wham/usage` response body.
    static func parseAPIResponse(jsonData: Data, now: Date = Date()) -> SupermuxCodexUsageSnapshot? {
        guard let payload = try? JSONDecoder().decode(APIPayload.self, from: jsonData) else { return nil }
        var windows: [SupermuxUsageWindow] = []
        if let rateLimit = payload.rateLimit {
            windows += [rateLimit.primaryWindow, rateLimit.secondaryWindow]
                .compactMap { $0 }
                .compactMap { window(fromAPI: $0) }
        }
        for extra in payload.additionalRateLimits ?? [] {
            guard let name = extra.limitName, !name.isEmpty else { continue }
            // The promotional Codex Spark pool is hidden by user request; other
            // scoped pools keep rendering (surfacing only their tightest window).
            if Self.hiddenScopedLimitNames.contains(name.lowercased()) { continue }
            let candidates = [extra.rateLimit?.primaryWindow, extra.rateLimit?.secondaryWindow]
                .compactMap { $0 }
                .compactMap { window(fromAPI: $0) }
            if let tightest = candidates.tightest {
                windows.append(SupermuxUsageWindow(
                    kind: .scoped(name),
                    percent: tightest.percent,
                    resetsAt: tightest.resetsAt
                ))
            }
        }
        guard !windows.isEmpty else { return nil }
        return SupermuxCodexUsageSnapshot(
            source: .api,
            planType: payload.planType,
            windows: windows,
            fetchedAt: now
        )
    }

    /// `nil` when the wire window carries no usable percentage — a missing
    /// value must not render as 0% ("unknown" is not "unused").
    private static func window(fromAPI wire: APIPayload.Window) -> SupermuxUsageWindow? {
        guard let percent = SupermuxUsagePercent.normalized(wire.usedPercent) else { return nil }
        let isSession = wire.limitWindowSeconds.map { $0 <= sessionWindowSeconds } ?? false
        return SupermuxUsageWindow(
            kind: isSession ? .session : .weekly,
            percent: percent,
            resetsAt: wire.resetAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - Session rollout log events

    /// Extracts the newest `rate_limits` snapshot from Codex session rollout
    /// JSONL content (last matching event wins). Used when the API is
    /// unreachable or the token is expired — data is only as fresh as the
    /// last Codex turn.
    static func parseSessionLog(jsonlContent: String) -> SupermuxCodexUsageSnapshot? {
        // Scan from the end until an event yields renderable windows: the
        // newest rate_limits event can be credits-only (its `primary`/
        // `secondary` absent), and stopping there would discard an older but
        // perfectly usable snapshot further up the file.
        for line in jsonlContent.split(separator: "\n").reversed() {
            guard line.contains("rate_limits") else { continue }
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(LogEvent.self, from: data),
                  let rateLimits = event.payload?.rateLimits else { continue }
            let windows: [SupermuxUsageWindow] = [rateLimits.primary, rateLimits.secondary]
                .compactMap { $0 }
                .compactMap { window(fromLog: $0) }
            guard !windows.isEmpty else { continue }
            return SupermuxCodexUsageSnapshot(
                source: .sessionLog,
                planType: rateLimits.planType,
                windows: windows,
                fetchedAt: event.timestamp.flatMap(SupermuxCswapUsageParser.parseISODate) ?? Date()
            )
        }
        return nil
    }

    /// `nil` when the log window carries no usable percentage.
    private static func window(fromLog wire: LogWindow) -> SupermuxUsageWindow? {
        guard let percent = SupermuxUsagePercent.normalized(wire.usedPercent) else { return nil }
        let isSession = wire.windowMinutes.map { $0 <= sessionWindowMinutes } ?? false
        return SupermuxUsageWindow(
            kind: isSession ? .session : .weekly,
            percent: percent,
            resetsAt: wire.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - Wire types

    private struct APIPayload: Decodable {
        let planType: String?
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalRateLimit]?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        struct AdditionalRateLimit: Decodable {
            let limitName: String?
            let rateLimit: RateLimit?

            enum CodingKeys: String, CodingKey {
                case limitName = "limit_name"
                case rateLimit = "rate_limit"
            }
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Double?
            let resetAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case limitWindowSeconds = "limit_window_seconds"
                case resetAt = "reset_at"
            }
        }
    }

    private struct LogEvent: Decodable {
        let timestamp: String?
        let payload: LogEventPayload?
    }

    private struct LogEventPayload: Decodable {
        let rateLimits: LogRateLimits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    struct LogRateLimits: Decodable {
        let primary: LogWindow?
        let secondary: LogWindow?
        let planType: String?

        enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case planType = "plan_type"
        }
    }

    struct LogWindow: Decodable {
        let usedPercent: Double?
        let windowMinutes: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }
}

public import Foundation

/// Fetches Codex (ChatGPT-subscription) usage limits.
///
/// Primary: `GET https://chatgpt.com/backend-api/wham/usage` with the access
/// token + account id from `~/.codex/auth.json` — the exact call the Codex
/// TUI makes every 60s for its own status display. The token is a ~10-day JWT
/// the CLI refreshes itself; this source NEVER refreshes it (the refresh
/// token rotates, and failing to persist the rotation would invalidate the
/// user's Codex login), so an expired token degrades to the session-log
/// fallback plus a `.needsLogin` hint.
///
/// Fallback: the newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` file
/// carries a `rate_limits` snapshot per turn — no network, but only as fresh
/// as the last Codex run.
public actor SupermuxCodexUsageSource {
    private let session: URLSession
    private let codexDirectory: URL
    private let usageEndpoint: URL

    public init(
        session: URLSession = .shared,
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex"),
        usageEndpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) {
        self.session = session
        self.codexDirectory = codexDirectory
        self.usageEndpoint = usageEndpoint
    }

    public func fetch() async -> SupermuxUsageProviderState<SupermuxCodexUsageSnapshot> {
        guard let auth = readAuth() else {
            // No auth.json at all → Codex CLI absent or never logged in.
            // A session log without auth is possible but useless long-term;
            // still surface it if present so the row isn't blank.
            if let fromLog = readNewestSessionLogSnapshot() {
                return .ready(fromLog)
            }
            return .notConfigured
        }
        if let expiry = Self.jwtExpiry(auth.accessToken), expiry <= Date() {
            if let fromLog = readNewestSessionLogSnapshot() {
                return .ready(fromLog)
            }
            return .needsLogin(detail: nil)
        }
        var request = URLRequest(url: usageEndpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = auth.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return degrade(message: "invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                if let fromLog = readNewestSessionLogSnapshot() {
                    return .ready(fromLog)
                }
                return .needsLogin(detail: "HTTP \(http.statusCode)")
            }
            guard (200..<300).contains(http.statusCode) else {
                return degrade(message: "HTTP \(http.statusCode)")
            }
            guard let snapshot = SupermuxCodexUsageParser.parseAPIResponse(jsonData: data) else {
                return degrade(message: "unexpected usage format")
            }
            return .ready(snapshot)
        } catch {
            return degrade(message: error.localizedDescription)
        }
    }

    /// A failed API attempt still serves the local session-log snapshot when
    /// one exists, so transient network trouble never blanks the row.
    private func degrade(message: String) -> SupermuxUsageProviderState<SupermuxCodexUsageSnapshot> {
        if let fromLog = readNewestSessionLogSnapshot() {
            return .ready(fromLog)
        }
        return .failed(message: message)
    }

    // MARK: - auth.json

    private struct CodexAuth {
        let accessToken: String
        let accountId: String?
    }

    private func readAuth() -> CodexAuth? {
        let authURL = codexDirectory.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let parsed = try? JSONDecoder().decode(AuthFile.self, from: data),
              let token = parsed.tokens?.accessToken, !token.isEmpty else {
            return nil
        }
        return CodexAuth(accessToken: token, accountId: parsed.tokens?.accountId)
    }

    /// Decodes the `exp` claim from a JWT without verifying the signature
    /// (we only need a local staleness check before spending a request).
    static func jwtExpiry(_ jwt: String) -> Date? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONDecoder().decode(JWTClaims.self, from: data),
              let exp = claims.exp else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Session-log fallback

    private func readNewestSessionLogSnapshot() -> SupermuxCodexUsageSnapshot? {
        guard let newest = newestRolloutFile() else { return nil }
        // Rollout files grow with the session; reading the whole file is fine
        // (they are line-delimited JSON, typically well under a few MB) and the
        // parser scans from the end for the last rate_limits event.
        guard let content = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        return SupermuxCodexUsageParser.parseSessionLog(jsonlContent: content)
    }

    /// The lexicographically-last rollout file in the lexicographically-last
    /// day/month/year directories — the date-based layout makes name order
    /// equal recency order, without stat-ing every historical file.
    private func newestRolloutFile() -> URL? {
        let sessionsRoot = codexDirectory.appendingPathComponent("sessions")
        var directory = sessionsRoot
        // sessions/YYYY/MM/DD
        for _ in 0..<3 {
            guard let last = lastNameSorted(in: directory, directoriesOnly: true) else { return nil }
            directory = last
        }
        return lastNameSorted(in: directory, directoriesOnly: false, prefix: "rollout-")
    }

    private func lastNameSorted(in directory: URL, directoriesOnly: Bool, prefix: String? = nil) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { url in
                if let prefix, !url.lastPathComponent.hasPrefix(prefix) { return false }
                guard directoriesOnly else { return true }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Wire types

    private struct AuthFile: Decodable {
        let tokens: Tokens?

        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }
    }

    private struct JWTClaims: Decodable {
        let exp: Double?
    }
}

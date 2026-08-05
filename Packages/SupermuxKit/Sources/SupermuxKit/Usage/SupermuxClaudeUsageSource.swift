public import Foundation
public import CmuxFoundation

/// Fetches Claude Code subscription usage, preferring the user's `cswap`
/// install and falling back to Anthropic's OAuth usage endpoint directly.
///
/// cswap path: `cswap list --json` returns every managed account with 5h/7d
/// windows, per-model weekly limits, and the active account marked — served
/// from cswap's own cache, so it never spends the usage endpoint's tight
/// per-token budget (~28-30 requests/rolling hour) on our behalf.
///
/// Direct path (no cswap): reads Claude Code's own credential (macOS Keychain
/// service "Claude Code-credentials" via `security`, else
/// `~/.claude/.credentials.json`) and calls `GET /api/oauth/usage` with it.
/// Never refreshes the token — Claude Code owns that credential and rotates
/// it; racing its refresh could log the user out. An expired token surfaces
/// as `.tokenExpired` until Claude Code's next run refreshes it.
public actor SupermuxClaudeUsageSource {
    private let runner: any CommandRunning
    private let session: URLSession
    private let homeDirectory: URL
    /// Test seam: overrides the usage endpoint URL.
    private let usageEndpoint: URL
    /// Serve-from-cache TTL for the DIRECT endpoint only (mirrors cswap's own
    /// 180s SERVE_TTL): with Anthropic's ~28-30 requests/rolling-hour/token
    /// budget shared with Claude Code itself, the raw endpoint must never be
    /// hit more than ~20×/hour no matter how often the UI asks. cswap results
    /// are not cached here — cswap already serves from its own cache.
    private let directServeTTL: TimeInterval
    private var lastDirectResult: SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>?
    private var lastDirectFetchAt: Date?

    public init(
        // Extend the runner's fallback search with the uv/pipx install dir
        // (`~/.local/bin`, where cswap typically lands): a Finder-launched
        // app's PATH has none of the user's shell additions.
        runner: any CommandRunning = CommandRunner(
            fallbackSearchDirectories: CommandRunner.defaultFallbackSearchDirectories + [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin").path,
            ]
        ),
        session: URLSession = .shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        usageEndpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        directServeTTL: TimeInterval = 180
    ) {
        self.runner = runner
        self.session = session
        self.homeDirectory = homeDirectory
        self.usageEndpoint = usageEndpoint
        self.directServeTTL = directServeTTL
    }

    /// One fetch attempt: cswap when available, else the direct API.
    public func fetch() async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> {
        if let viaCswap = await fetchViaCswap() {
            return viaCswap
        }
        return await fetchDirect()
    }

    // MARK: - cswap

    /// Switches the active Claude Code login to the given cswap slot by
    /// running `cswap switch <slot> --json`. cswap owns the whole mutation
    /// (credential backup/restore under Claude Code's own locks); this method
    /// only shells out and interprets the envelope. On success the caller
    /// should force a usage refresh so the popover re-labels the active row.
    public func switchAccount(toSlot slot: Int) async -> SupermuxCswapSwitchResult {
        // Invalidate the direct-path cache: after a switch the active
        // credential changes, so a cached single-account result is stale.
        lastDirectResult = nil
        lastDirectFetchAt = nil
        let result = await runner.run(
            directory: homeDirectory.path,
            executable: "cswap",
            arguments: ["switch", String(slot), "--json"],
            timeout: 60
        )
        if result.executionError != nil || result.exitStatus == 127 || result.exitStatus == 126 {
            return .failed(message: "cswap not found")
        }
        if result.timedOut {
            return .failed(message: "cswap switch timed out")
        }
        // cswap emits its JSON envelope on stdout for success AND handled
        // errors (error_envelope); parse whatever came back before falling
        // back to stderr.
        if let stdout = result.stdout, let data = stdout.data(using: .utf8),
           let parsed = SupermuxCswapSwitchResult.parse(jsonData: data) {
            return parsed
        }
        let detail = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message: detail?.isEmpty == false ? detail! : "cswap switch failed")
    }

    /// `nil` when cswap is not installed (falls through to the direct path);
    /// any other outcome is terminal for this attempt.
    private func fetchViaCswap() async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>? {
        let result = await runner.run(
            directory: homeDirectory.path,
            executable: "cswap",
            arguments: ["list", "--json"],
            timeout: 20
        )
        // Binary absent → fall through to the direct path. Two shapes: a
        // launch failure (absolute path missing), or — because CommandRunner
        // runs unresolved names through `/usr/bin/env` — a clean launch that
        // exits 127 ("command not found"; 126 = found but not executable).
        if result.executionError != nil { return nil }
        if result.exitStatus == 127 || result.exitStatus == 126 { return nil }
        guard !result.timedOut, result.exitStatus == 0,
              let stdout = result.stdout, !stdout.isEmpty,
              let data = stdout.data(using: .utf8) else {
            let detail = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message: detail?.isEmpty == false ? detail! : "cswap list failed")
        }
        guard let snapshot = SupermuxCswapUsageParser.parse(jsonData: data) else {
            return .failed(message: "cswap returned an unexpected format")
        }
        guard !snapshot.accounts.isEmpty else { return .notConfigured }
        return .ready(snapshot)
    }

    // MARK: - Direct API fallback

    private func fetchDirect() async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> {
        // Serve the previous direct result while inside the TTL: this is the
        // hard bound on raw endpoint spend, independent of UI cadence.
        if let cached = lastDirectResult, let at = lastDirectFetchAt,
           Date().timeIntervalSince(at) < directServeTTL {
            return cached
        }
        let fresh = await fetchDirectUncached()
        lastDirectResult = fresh
        lastDirectFetchAt = Date()
        return fresh
    }

    private func fetchDirectUncached() async -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> {
        guard let credential = await readClaudeCredential() else {
            return .notConfigured
        }
        if let expiresAt = credential.expiresAt, expiresAt <= Date() {
            return .needsLogin(detail: nil)
        }
        var request = URLRequest(url: usageEndpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(message: "invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .needsLogin(detail: "HTTP \(http.statusCode)")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(message: "HTTP \(http.statusCode)")
            }
            guard let account = Self.parseDirectUsage(
                jsonData: data,
                email: credential.email
            ) else {
                return .failed(message: "unexpected usage format")
            }
            return .ready(SupermuxClaudeUsageSnapshot(
                source: .directAPI,
                accounts: [account],
                fetchedAt: Date()
            ))
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Credential discovery (read-only; never refreshes)

    private struct ClaudeCredential {
        let accessToken: String
        let expiresAt: Date?
        let email: String
    }

    private func readClaudeCredential() async -> ClaudeCredential? {
        let blob: Data?
        // Keychain first (Claude Code's default store on macOS), then the
        // plaintext fallback file some setups use.
        if let keychain = await readKeychainCredential() {
            blob = keychain
        } else {
            let fileURL = homeDirectory
                .appendingPathComponent(".claude")
                .appendingPathComponent(".credentials.json")
            blob = try? Data(contentsOf: fileURL)
        }
        guard let blob,
              let parsed = try? JSONDecoder().decode(CredentialFile.self, from: blob),
              let oauth = parsed.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty else {
            return nil
        }
        return ClaudeCredential(
            accessToken: token,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            email: readActiveAccountEmail() ?? ""
        )
    }

    private func readKeychainCredential() async -> Data? {
        let result = await runner.run(
            directory: homeDirectory.path,
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: 10
        )
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0,
              let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stdout.isEmpty else {
            return nil
        }
        return stdout.data(using: .utf8)
    }

    private func readActiveAccountEmail() -> String? {
        let configURL = homeDirectory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configURL),
              let parsed = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else {
            return nil
        }
        return parsed.oauthAccount?.emailAddress
    }

    // MARK: - Direct-response parsing

    /// Parses the raw `/api/oauth/usage` body (five_hour/seven_day plus the
    /// newer `limits[]` array carrying scoped per-model weeklies).
    static func parseDirectUsage(jsonData: Data, email: String) -> SupermuxClaudeAccountUsage? {
        guard let payload = try? JSONDecoder().decode(DirectUsagePayload.self, from: jsonData) else {
            return nil
        }
        var windows: [SupermuxUsageWindow] = []
        if let window = payload.fiveHour {
            windows.append(SupermuxUsageWindow(
                kind: .session,
                percent: window.utilization ?? 0,
                resetsAt: window.resetsAt.flatMap(SupermuxCswapUsageParser.parseISODate)
            ))
        }
        if let window = payload.sevenDay {
            windows.append(SupermuxUsageWindow(
                kind: .weekly,
                percent: window.utilization ?? 0,
                resetsAt: window.resetsAt.flatMap(SupermuxCswapUsageParser.parseISODate)
            ))
        }
        for limit in payload.limits ?? [] where limit.kind == "weekly_scoped" {
            guard let name = limit.scope?.model?.displayName, !name.isEmpty else { continue }
            windows.append(SupermuxUsageWindow(
                kind: .scoped(name),
                percent: limit.percent ?? 0,
                resetsAt: limit.resetsAt.flatMap(SupermuxCswapUsageParser.parseISODate)
            ))
        }
        guard !windows.isEmpty else { return nil }
        return SupermuxClaudeAccountUsage(
            email: email,
            displayName: nil,
            isActive: true,
            status: .ok,
            windows: windows,
            fetchedAt: Date()
        )
    }

    // MARK: - Wire types

    private struct CredentialFile: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
        }
    }

    private struct ClaudeConfig: Decodable {
        let oauthAccount: OAuthAccount?

        struct OAuthAccount: Decodable {
            let emailAddress: String?
        }
    }

    struct DirectUsagePayload: Decodable {
        let fiveHour: DirectWindow?
        let sevenDay: DirectWindow?
        let limits: [DirectLimit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }
    }

    struct DirectWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct DirectLimit: Decodable {
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind
            case percent
            case resetsAt = "resets_at"
            case scope
        }

        struct Scope: Decodable {
            let model: Model?

            struct Model: Decodable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }
        }
    }
}

import Foundation

/// Short, cswap-TUI-style labels for per-account credential problems.
/// `nil` for `.ok` (the caller renders normal usage instead).
enum SupermuxUsageAccountStatusLabel {
    static func text(for status: SupermuxClaudeAccountUsage.Status) -> String? {
        switch status {
        case .ok:
            return nil
        case .tokenExpired:
            return String(localized: "supermux.usage.status.tokenExpired", defaultValue: "token expired")
        case .reloginRequired:
            return String(localized: "supermux.usage.status.reloginRequired", defaultValue: "re-login needed")
        case .unavailable(let reason):
            // cswap's sentinel strings arrive snake_cased ("keychain_unavailable",
            // "foreign_credential", "no_credentials", "api_key"); known ones get
            // proper localized labels, the rest render as-is (better a raw hint
            // than a blank).
            switch reason {
            case "keychain_unavailable":
                return String(localized: "supermux.usage.status.keychainUnavailable", defaultValue: "keychain locked")
            case "no_credentials":
                return String(localized: "supermux.usage.status.noCredentials", defaultValue: "no credentials")
            case "foreign_credential":
                return String(localized: "supermux.usage.status.foreignCredential", defaultValue: "foreign login")
            case "api_key":
                return String(localized: "supermux.usage.status.apiKey", defaultValue: "API key (no quota)")
            case let other?:
                return other.replacingOccurrences(of: "_", with: " ")
            case nil:
                return String(localized: "supermux.usage.status.unavailable", defaultValue: "unavailable")
            }
        }
    }
}

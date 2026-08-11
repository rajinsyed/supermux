public import Foundation
public import SupermuxMobileCore

/// Pure text rules for the usage sheet's account rows, kept off the views so
/// the fallbacks are unit-testable: a malformed cswap row (no alias, no
/// email, no slot) must still produce a readable name, and every credential
/// problem must produce a short amber label rather than a blank.
/// lint:allow namespace-enum — stateless label rules shared by the sheet's active and other-account rows.
public enum SupermuxUsageAccountLabels {
    /// The row's display name. Never blank: alias, then email, then the slot
    /// number, then a generic fallback.
    /// - Parameter account: The account row.
    public static func name(for account: SupermuxUsageAccountDTO) -> String {
        if let displayName = account.displayName, !displayName.isEmpty { return displayName }
        if let email = account.email, !email.isEmpty { return email }
        if let slot = account.slot {
            return String(
                format: String(
                    localized: "supermux.usage.account.slotFallback",
                    defaultValue: "Account %lld",
                    bundle: .module
                ),
                slot
            )
        }
        return String(
            localized: "supermux.usage.account.unknown",
            defaultValue: "Unknown account",
            bundle: .module
        )
    }

    /// A short, cswap-TUI-style label for a credential problem, or `nil` when
    /// the account is healthy (the caller renders usage instead).
    ///
    /// cswap's sentinels arrive snake_cased; known ones get proper localized
    /// labels and the rest render de-snaked — better a raw hint than a blank.
    ///
    /// - Parameter account: The account row.
    public static func statusText(for account: SupermuxUsageAccountDTO) -> String? {
        switch account.status {
        case nil, SupermuxUsageAccountDTO.okStatus:
            return nil
        case "token_expired":
            return String(
                localized: "supermux.usage.status.tokenExpired",
                defaultValue: "token expired",
                bundle: .module
            )
        case "relogin_required":
            return String(
                localized: "supermux.usage.status.reloginRequired",
                defaultValue: "re-login needed",
                bundle: .module
            )
        case "unavailable":
            return unavailableText(detail: account.statusDetail)
        case let unknown?:
            // A newer Mac's status string: de-snake it rather than dropping
            // the fact that something is wrong with this account.
            return unknown.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The label for an `unavailable` account, mapping cswap's known reason
    /// sentinels onto localized text.
    private static func unavailableText(detail: String?) -> String {
        switch detail {
        case "keychain_unavailable":
            String(
                localized: "supermux.usage.status.keychainUnavailable",
                defaultValue: "keychain locked",
                bundle: .module
            )
        case "no_credentials":
            String(
                localized: "supermux.usage.status.noCredentials",
                defaultValue: "no credentials",
                bundle: .module
            )
        case "foreign_credential":
            String(
                localized: "supermux.usage.status.foreignCredential",
                defaultValue: "foreign login",
                bundle: .module
            )
        case "api_key":
            String(
                localized: "supermux.usage.status.apiKey",
                defaultValue: "API key (no quota)",
                bundle: .module
            )
        case let other? where !other.isEmpty:
            other.replacingOccurrences(of: "_", with: " ")
        default:
            String(
                localized: "supermux.usage.status.unavailable",
                defaultValue: "unavailable",
                bundle: .module
            )
        }
    }
}

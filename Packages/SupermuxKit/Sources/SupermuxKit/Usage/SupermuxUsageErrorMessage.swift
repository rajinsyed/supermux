import Foundation

/// Code-owned fallback error strings rendered in the usage popover.
///
/// Only OUR fallback wording is localized here; text passed through from
/// cswap's stderr/JSON envelopes or `URLError.localizedDescription` stays
/// verbatim — it is external output, and mangling it would hide the actual
/// problem.
enum SupermuxUsageErrorMessage {
    static var cswapNotFound: String {
        String(localized: "supermux.usage.error.cswapNotFound", defaultValue: "cswap not found")
    }

    static var cswapSwitchTimedOut: String {
        String(localized: "supermux.usage.error.cswapSwitchTimedOut", defaultValue: "cswap switch timed out")
    }

    static var cswapSwitchFailed: String {
        String(localized: "supermux.usage.error.cswapSwitchFailed", defaultValue: "cswap switch failed")
    }

    static var cswapDidNotSwitch: String {
        String(localized: "supermux.usage.error.cswapDidNotSwitch", defaultValue: "cswap did not switch")
    }

    static var cswapListFailed: String {
        String(localized: "supermux.usage.error.cswapListFailed", defaultValue: "cswap list failed")
    }

    static var cswapUnexpectedFormat: String {
        String(localized: "supermux.usage.error.cswapUnexpectedFormat", defaultValue: "cswap returned an unexpected format")
    }

    static func cswapCommandFailed(_ verb: String) -> String {
        String(
            format: String(localized: "supermux.usage.error.cswapCommandFailed", defaultValue: "cswap %@ failed"),
            verb
        )
    }

    static var invalidResponse: String {
        String(localized: "supermux.usage.error.invalidResponse", defaultValue: "invalid response")
    }

    static var unexpectedUsageFormat: String {
        String(localized: "supermux.usage.error.unexpectedFormat", defaultValue: "unexpected usage format")
    }

    static func httpStatus(_ code: Int) -> String {
        String(
            format: String(localized: "supermux.usage.error.httpStatus", defaultValue: "HTTP %lld"),
            code
        )
    }
}

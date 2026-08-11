public import SupermuxMobileCore

/// `mobile.supermux.usage.state`: `{}` — the Mac's current Claude Code +
/// Codex rate-limit snapshot. Read-only: the phone mirrors the Mac's usage
/// model and never mutates a cswap account.
public struct SupermuxUsageStateRequest: Equatable, Sendable {
    /// Creates the request.
    public init() {}

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.usageState.rawValue }

    /// The exact wire params (none).
    public var wireParams: [String: Any] { [:] }
}

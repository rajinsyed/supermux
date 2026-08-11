import Foundation
internal import SupermuxMobileCore

/// Builds the `mobile.supermux.usage.state` result payload from the SAME
/// ``SupermuxUsageModel`` states the desktop popover renders, so the phone can
/// never disagree with the sidebar gauge about a limit.
///
/// Lives in SupermuxKit (not the app target) so the wire projection is
/// package-unit-testable against value snapshots; the app handler stays a thin
/// pass-through reading `SupermuxComposition.usageModel`.
///
/// The projection is read-only by design: the phone mirrors limits and never
/// switches or disables a cswap account (the AI credentials stay Mac-side,
/// like the AI gateway key).
public struct SupermuxMobileUsagePayloadBuilder: Sendable {
    /// Creates a builder. Stateless; construct wherever needed.
    public init() {}

    /// Encodes the `usage.state` result: `{claude: …, codex: …}`.
    ///
    /// - Parameters:
    ///   - claude: The model's Claude provider state.
    ///   - codex: The model's Codex provider state.
    /// - Returns: The RPC result object.
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func usageState(
        claude: SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>,
        codex: SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>
    ) throws -> [String: Any] {
        try SupermuxWireJSON().dictionary(from: SupermuxUsageStateDTO(
            claude: Self.provider(claude),
            codex: Self.provider(codex)
        ))
    }

    // MARK: - Providers

    /// The Claude column: state, source, and one row per known account
    /// (active first, matching the popover's order).
    static func provider(
        _ state: SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>
    ) -> SupermuxUsageProviderDTO {
        switch state {
        case .loading:
            return SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.loadingState)
        case .notConfigured:
            return SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.notConfiguredState)
        case .needsLogin(let detail):
            return SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.needsLoginState,
                message: detail
            )
        case .failed(let message):
            return SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.failedState,
                message: message
            )
        case .ready(let snapshot):
            return SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                source: snapshot.source == .cswap
                    ? SupermuxUsageProviderDTO.cswapSource
                    : "direct_api",
                accounts: snapshot.accounts.map(account),
                fetchedAt: snapshot.fetchedAt.timeIntervalSince1970
            )
        }
    }

    /// The Codex column: state, source, plan, and its own windows.
    static func provider(
        _ state: SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>
    ) -> SupermuxUsageProviderDTO {
        switch state {
        case .loading:
            return SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.loadingState)
        case .notConfigured:
            return SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.notConfiguredState)
        case .needsLogin(let detail):
            return SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.needsLoginState,
                message: detail
            )
        case .failed(let message):
            return SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.failedState,
                message: message
            )
        case .ready(let snapshot):
            return SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                source: snapshot.source == .api
                    ? "api"
                    : SupermuxUsageProviderDTO.sessionLogSource,
                planType: snapshot.planType,
                needsRelogin: snapshot.needsRelogin,
                windows: snapshot.windows.map(window),
                fetchedAt: snapshot.fetchedAt.timeIntervalSince1970
            )
        }
    }

    // MARK: - Rows

    /// One Claude account row. The model's `id` travels verbatim so the
    /// phone's list identity matches the Mac's, even for malformed cswap rows
    /// carrying neither a slot nor an email.
    static func account(_ account: SupermuxClaudeAccountUsage) -> SupermuxUsageAccountDTO {
        let (status, detail) = statusStrings(account.status)
        return SupermuxUsageAccountDTO(
            id: account.id,
            slot: account.slot,
            email: account.email.isEmpty ? nil : account.email,
            displayName: account.displayName,
            isActive: account.isActive,
            isDisabled: account.isDisabled,
            status: status,
            statusDetail: detail,
            windows: account.windows.map(window),
            fetchedAt: account.fetchedAt?.timeIntervalSince1970
        )
    }

    /// One limit window. `scoped` windows carry their provider label; the
    /// session and weekly kinds are labeled phone-side so both platforms use
    /// their own localization.
    static func window(_ window: SupermuxUsageWindow) -> SupermuxUsageWindowDTO {
        let kind: String
        var label: String?
        switch window.kind {
        case .session:
            kind = SupermuxUsageWindowDTO.sessionKind
        case .weekly:
            kind = SupermuxUsageWindowDTO.weeklyKind
        case .scoped(let name):
            kind = SupermuxUsageWindowDTO.scopedKind
            label = name
        }
        return SupermuxUsageWindowDTO(
            kind: kind,
            label: label,
            percent: window.percent,
            resetsAt: window.resetsAt?.timeIntervalSince1970,
            aheadOfPace: window.aheadOfPace
        )
    }

    /// The account status split into its wire string and cswap's raw reason
    /// sentinel, which the phone maps to its own localized labels.
    static func statusStrings(
        _ status: SupermuxClaudeAccountUsage.Status
    ) -> (status: String, detail: String?) {
        switch status {
        case .ok:
            (SupermuxUsageAccountDTO.okStatus, nil)
        case .tokenExpired:
            ("token_expired", nil)
        case .reloginRequired:
            ("relogin_required", nil)
        case .unavailable(let reason):
            ("unavailable", reason)
        }
    }
}

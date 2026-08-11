import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// The Mac-side `usage.state` projection: every desktop model state maps onto
/// the wire contract the phone decodes, so the two surfaces can never
/// disagree about a limit.
@Suite struct SupermuxMobileUsagePayloadTests {
    private let builder = SupermuxMobileUsagePayloadBuilder()

    private func decodedState(
        claude: SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot>,
        codex: SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>
    ) throws -> SupermuxUsageStateDTO {
        let payload = try builder.usageState(claude: claude, codex: codex)
        return try SupermuxWireJSON().decode(SupermuxUsageStateDTO.self, from: payload)
    }

    // MARK: - Provider states

    @Test func everyProviderStateMapsOntoItsWireString() throws {
        let cases: [(SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>, String, String?)] = [
            (.loading, SupermuxUsageProviderDTO.loadingState, nil),
            (.notConfigured, SupermuxUsageProviderDTO.notConfiguredState, nil),
            (.needsLogin(detail: "expired"), SupermuxUsageProviderDTO.needsLoginState, "expired"),
            (.failed(message: "boom"), SupermuxUsageProviderDTO.failedState, "boom"),
        ]
        for (state, expected, message) in cases {
            let decoded = try decodedState(claude: .loading, codex: state)
            #expect(decoded.codex.state == expected)
            #expect(decoded.codex.message == message)
            // A non-ready provider contributes nothing to the phone's gauge.
            #expect(decoded.codex.gaugeWindows.isEmpty)
        }
    }

    @Test func readyClaudeCarriesItsSourceAccountsAndWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let snapshot = SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [
                SupermuxClaudeAccountUsage(
                    slot: 1,
                    ordinal: 0,
                    email: "rajin@example.com",
                    displayName: "Rajin",
                    isActive: true,
                    isDisabled: false,
                    status: .ok,
                    windows: [
                        SupermuxUsageWindow(kind: .session, percent: 47, resetsAt: fetchedAt),
                        SupermuxUsageWindow(kind: .weekly, percent: 81, resetsAt: nil, aheadOfPace: true),
                        SupermuxUsageWindow(kind: .scoped("Fable"), percent: 12, resetsAt: nil),
                    ],
                    fetchedAt: fetchedAt
                ),
            ],
            fetchedAt: fetchedAt
        )

        let decoded = try decodedState(claude: .ready(snapshot), codex: .loading)

        #expect(decoded.claude.state == SupermuxUsageProviderDTO.readyState)
        #expect(decoded.claude.source == SupermuxUsageProviderDTO.cswapSource)
        #expect(decoded.claude.fetchedAt == fetchedAt.timeIntervalSince1970)
        let account = try #require(decoded.claude.activeAccount)
        // The identity travels verbatim so the phone's row identity matches
        // the Mac's, even for malformed cswap rows.
        #expect(account.id == snapshot.accounts[0].id)
        #expect(account.slot == 1)
        #expect(account.email == "rajin@example.com")
        #expect(account.displayName == "Rajin")
        #expect(account.isActive == true)
        #expect(account.isDisabled == false)
        #expect(account.status == SupermuxUsageAccountDTO.okStatus)
        #expect(account.fetchedAt == fetchedAt.timeIntervalSince1970)

        let windows = account.displayWindows
        #expect(windows.map(\.kind) == ["session", "weekly", "scoped"])
        #expect(windows[0].resetsAt == fetchedAt.timeIntervalSince1970)
        #expect(windows[1].aheadOfPace == true)
        // Only a scoped window carries the provider's label; the other two
        // are labeled by each platform's own localization.
        #expect(windows[0].label == nil)
        #expect(windows[2].label == "Fable")
    }

    @Test func directAPIClaudeReportsItsOwnSource() throws {
        let snapshot = SupermuxClaudeUsageSnapshot(
            source: .directAPI,
            accounts: [],
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
        let decoded = try decodedState(claude: .ready(snapshot), codex: .loading)
        #expect(decoded.claude.source == "direct_api")
    }

    @Test func readyCodexCarriesPlanSourceAndReloginMarker() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_770_000_500)
        let snapshot = SupermuxCodexUsageSnapshot(
            source: .sessionLog,
            planType: "pro",
            windows: [SupermuxUsageWindow(kind: .session, percent: 19, resetsAt: nil)],
            fetchedAt: fetchedAt,
            needsRelogin: true
        )

        let decoded = try decodedState(claude: .loading, codex: .ready(snapshot))

        #expect(decoded.codex.state == SupermuxUsageProviderDTO.readyState)
        #expect(decoded.codex.source == SupermuxUsageProviderDTO.sessionLogSource)
        #expect(decoded.codex.planType == "pro")
        #expect(decoded.codex.needsRelogin == true)
        #expect(decoded.codex.windows?.count == 1)
        #expect(decoded.codex.fetchedAt == fetchedAt.timeIntervalSince1970)
    }

    // MARK: - Account status

    @Test func everyAccountStatusMapsOntoItsWireStringAndDetail() {
        #expect(
            SupermuxMobileUsagePayloadBuilder.statusStrings(.ok).status
                == SupermuxUsageAccountDTO.okStatus
        )
        #expect(SupermuxMobileUsagePayloadBuilder.statusStrings(.tokenExpired).status == "token_expired")
        #expect(SupermuxMobileUsagePayloadBuilder.statusStrings(.reloginRequired).status == "relogin_required")
        let unavailable = SupermuxMobileUsagePayloadBuilder.statusStrings(
            .unavailable(reason: "keychain_unavailable")
        )
        #expect(unavailable.status == "unavailable")
        // cswap's raw sentinel travels so the phone can localize it.
        #expect(unavailable.detail == "keychain_unavailable")
        #expect(SupermuxMobileUsagePayloadBuilder.statusStrings(.unavailable(reason: nil)).detail == nil)
    }

    /// The desktop gauge and the phone gauge must pick the same window, so
    /// the projection preserves the tightest-window verdict end to end.
    @Test func tightestWindowSurvivesTheProjection() throws {
        let claude = SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [SupermuxClaudeAccountUsage(
                slot: 1,
                email: "a@example.com",
                displayName: nil,
                isActive: true,
                status: .ok,
                windows: [SupermuxUsageWindow(kind: .weekly, percent: 61, resetsAt: nil)],
                fetchedAt: nil
            )],
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
        let codex = SupermuxCodexUsageSnapshot(
            source: .api,
            planType: nil,
            windows: [SupermuxUsageWindow(kind: .session, percent: 88, resetsAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 1)
        )

        let decoded = try decodedState(claude: .ready(claude), codex: .ready(codex))

        let macTightest = ([SupermuxUsageWindow](claude.activeAccount?.windows ?? []) + codex.windows).tightest
        #expect(decoded.tightestWindow?.percent == macTightest?.percent)
        #expect(decoded.tightestWindow?.percent == 88)
    }

    @Test func anEmptyAccountListStillEncodesAReadyProvider() throws {
        let snapshot = SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [],
            fetchedAt: Date(timeIntervalSince1970: 5)
        )
        let decoded = try decodedState(claude: .ready(snapshot), codex: .loading)
        #expect(decoded.claude.state == SupermuxUsageProviderDTO.readyState)
        #expect(decoded.claude.accounts?.isEmpty == true)
        #expect(decoded.claude.activeAccount == nil)
        #expect(decoded.tightestWindow == nil)
    }
}

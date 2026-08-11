import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// Presentation rules for the phone's usage surfaces: the capability gate on
/// the toolbar entry (UI-02), the account label fallbacks, the credential
/// status labels, and the per-row identity the sheet's `ForEach` uses.
@Suite struct SupermuxUsagePresentationTests {
    // MARK: - Capability gate (UI-02)

    @Test func toolbarButtonHidesWithoutTheUsageCapability() {
        #expect(!SupermuxUsageEntry.showsButton(hostCapabilities: nil))
        #expect(!SupermuxUsageEntry.showsButton(hostCapabilities: []))
        // An upstream cmux Mac: plenty of capabilities, none of them ours.
        #expect(!SupermuxUsageEntry.showsButton(hostCapabilities: [
            "workspace.groups.v1",
            "terminal.render_grid.v1",
        ]))
        // Another supermux capability must not light this entry point up.
        #expect(!SupermuxUsageEntry.showsButton(hostCapabilities: [
            SupermuxMobileCapability.projectsV1.rawValue,
        ]))
    }

    @Test func toolbarButtonShowsWithTheUsageCapability() {
        #expect(SupermuxUsageEntry.showsButton(hostCapabilities: [
            SupermuxMobileCapability.usageV1.rawValue,
        ]))
    }

    // MARK: - Account names

    /// A malformed cswap row can carry no alias, no email, and no slot; the
    /// row still needs a readable name for its label and accessibility.
    @Test func accountNameFallsBackThroughAliasEmailSlotThenGeneric() {
        let named = SupermuxUsageAccountDTO(
            id: "1|a@example.com",
            slot: 1,
            email: "a@example.com",
            displayName: "Rajin"
        )
        #expect(SupermuxUsageAccountLabels.name(for: named) == "Rajin")

        let emailOnly = SupermuxUsageAccountDTO(id: "1|a@example.com", slot: 1, email: "a@example.com")
        #expect(SupermuxUsageAccountLabels.name(for: emailOnly) == "a@example.com")

        let slotOnly = SupermuxUsageAccountDTO(id: "2|", slot: 2, email: "", displayName: "")
        #expect(SupermuxUsageAccountLabels.name(for: slotOnly).contains("2"))

        let nothing = SupermuxUsageAccountDTO(id: "#0|")
        #expect(!SupermuxUsageAccountLabels.name(for: nothing).isEmpty)
    }

    // MARK: - Credential status

    @Test func healthyAccountsCarryNoStatusLabel() {
        #expect(SupermuxUsageAccountLabels.statusText(
            for: SupermuxUsageAccountDTO(id: "1|", status: SupermuxUsageAccountDTO.okStatus)
        ) == nil)
        // An absent status (an older Mac's leaner payload) reads as healthy
        // rather than painting every account as broken.
        #expect(SupermuxUsageAccountLabels.statusText(for: SupermuxUsageAccountDTO(id: "1|")) == nil)
    }

    @Test func knownStatusesAndReasonsGetShortLabels() {
        for status in ["token_expired", "relogin_required"] {
            let text = SupermuxUsageAccountLabels.statusText(
                for: SupermuxUsageAccountDTO(id: "1|", status: status)
            )
            #expect(text?.isEmpty == false)
            // Localized labels, never the raw snake_cased sentinel.
            #expect(text?.contains("_") == false)
        }
        for reason in ["keychain_unavailable", "no_credentials", "foreign_credential", "api_key"] {
            let text = SupermuxUsageAccountLabels.statusText(for: SupermuxUsageAccountDTO(
                id: "1|",
                status: "unavailable",
                statusDetail: reason
            ))
            #expect(text?.isEmpty == false)
            #expect(text?.contains("_") == false)
        }
    }

    /// An unrecognized sentinel from a newer cswap must still say something —
    /// a raw hint beats a blank row.
    @Test func unknownStatusesAndReasonsDegradeToDeSnakedText() {
        #expect(SupermuxUsageAccountLabels.statusText(for: SupermuxUsageAccountDTO(
            id: "1|",
            status: "unavailable",
            statusDetail: "quota_frozen"
        )) == "quota frozen")
        #expect(SupermuxUsageAccountLabels.statusText(for: SupermuxUsageAccountDTO(
            id: "1|",
            status: "some_future_state"
        )) == "some future state")
        // `unavailable` with no reason still produces a label.
        #expect(SupermuxUsageAccountLabels.statusText(
            for: SupermuxUsageAccountDTO(id: "1|", status: "unavailable")
        )?.isEmpty == false)
    }

    // MARK: - Row identity

    /// Row identity is the window's KIND, not its index: index identity would
    /// morph a row into a different window when the set changes and animate
    /// percent between unrelated limits. Scoped windows share one kind, so
    /// they are additionally qualified by their label.
    @Test func windowIdentityIsStablePerKindAndUniquePerScopedLabel() {
        let windows = [
            SupermuxUsageWindowDTO(kind: SupermuxUsageWindowDTO.sessionKind, percent: 47),
            SupermuxUsageWindowDTO(kind: SupermuxUsageWindowDTO.weeklyKind, percent: 81),
            SupermuxUsageWindowDTO(kind: SupermuxUsageWindowDTO.scopedKind, label: "Fable", percent: 12),
            SupermuxUsageWindowDTO(kind: SupermuxUsageWindowDTO.scopedKind, label: "Spark", percent: 34),
        ]
        let identities = windows.map(\.identity)
        #expect(Set(identities).count == identities.count)
        // The identity must not move with the percent, or a live update would
        // read as a row replacement.
        var busier = windows[0]
        busier.percent = 99
        #expect(busier.identity == windows[0].identity)
    }

    // MARK: - Provider state notes

    /// Every non-ready provider state must say SOMETHING; only `ready` hands
    /// the section over to its rows.
    @Test func providerStateNotesCoverEveryStateAndHideOnlyWhenReady() {
        #expect(SupermuxUsageScreen.stateNote(
            for: SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.readyState),
            hasLoaded: true
        ) == nil)
        for state in [
            SupermuxUsageProviderDTO.loadingState,
            SupermuxUsageProviderDTO.notConfiguredState,
            SupermuxUsageProviderDTO.needsLoginState,
            SupermuxUsageProviderDTO.failedState,
        ] {
            #expect(SupermuxUsageScreen.stateNote(
                for: SupermuxUsageProviderDTO(state: state),
                hasLoaded: true
            )?.isEmpty == false)
        }
        // A newer Mac's unknown state must not blank the section.
        #expect(SupermuxUsageScreen.stateNote(
            for: SupermuxUsageProviderDTO(state: "some_future_state"),
            hasLoaded: true
        )?.isEmpty == false)
    }

    /// Before the first fetch lands, even a `ready`-looking payload reads as
    /// loading rather than as real (empty) data.
    @Test func nothingLoadedYetAlwaysReadsAsLoading() {
        #expect(SupermuxUsageScreen.stateNote(for: nil, hasLoaded: false)?.isEmpty == false)
        #expect(SupermuxUsageScreen.stateNote(
            for: SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.readyState),
            hasLoaded: false
        )?.isEmpty == false)
    }

    @Test func providerDetailShowsPlanForCodexAndAccountNameForClaude() {
        #expect(SupermuxUsageScreen.providerDetail(SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.readyState,
            planType: "pro"
        )) == "Pro")
        #expect(SupermuxUsageScreen.providerDetail(SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.readyState,
            accounts: [SupermuxUsageAccountDTO(
                id: "1|a@example.com",
                email: "a@example.com",
                isActive: true
            )]
        )) == "a@example.com")
        // A non-ready provider shows no detail: a stale email beside a
        // "signed out" note would read as live.
        #expect(SupermuxUsageScreen.providerDetail(SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.needsLoginState,
            planType: "pro"
        )) == nil)
        #expect(SupermuxUsageScreen.providerDetail(nil) == nil)
    }

    // MARK: - Style

    @Test func percentTextRoundsToWholePercentAndClamps() {
        #expect(SupermuxUsageStyle.percentText(0) == "0%")
        #expect(SupermuxUsageStyle.percentText(46.6) == "47%")
        #expect(SupermuxUsageStyle.percentText(-5) == "0%")
        #expect(SupermuxUsageStyle.percentText(140) == "100%")
    }
}

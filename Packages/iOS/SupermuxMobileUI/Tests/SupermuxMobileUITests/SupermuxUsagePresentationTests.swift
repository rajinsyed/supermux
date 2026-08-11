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

    // MARK: - Session lifecycle

    /// The gauge lives in the workspace list's `showsNavigationToolbar`
    /// branch, which is torn down on every navigation push. The session must
    /// therefore survive a push/pop: pausing the loop is fine, but losing the
    /// snapshot means the ring empties and polling restarts every time the
    /// user opens a workspace and comes back.
    @MainActor
    @Test func aPausedSessionKeepsItsStoreAndSnapshotForTheNextPop() async throws {
        let client = FakeSupermuxMacClient()
        client.usageStateResponse = SupermuxUsageStateDTO(
            claude: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                accounts: [SupermuxUsageAccountDTO(
                    id: "1|a",
                    isActive: true,
                    windows: [SupermuxUsageWindowDTO(kind: "session", percent: 47)]
                )]
            ),
            codex: SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.loadingState)
        )
        let model = SupermuxUsageSectionModel()
        let capabilities: Set<String> = [SupermuxMobileCapability.usageV1.rawValue]

        // A push cancels the driver's task; the session pauses.
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: capabilities,
                connectionID: "connection-1"
            )
        }
        try await TestWait().until { model.tightestWindow != nil }
        session.cancel()
        _ = await session.value

        // Paused, not torn down: the ring still shows its last reading.
        #expect(model.showsButton)
        #expect(model.tightestWindow?.percent == 47)
        let storeAfterPush = model.store

        // The pop re-runs the driver with the SAME connection identity, which
        // must resume the retained session rather than build a fresh one.
        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: capabilities,
                connectionID: "connection-1"
            )
        }
        try await TestWait().until { client.callLog.filter { $0 == "usageState" }.count >= 2 }
        resumed.cancel()
        _ = await resumed.value
        #expect(model.store === storeAfterPush)
    }

    /// A different connection (reconnect, or capabilities arriving late) must
    /// replace the session instead of polling a dead client.
    @MainActor
    @Test func aNewConnectionReplacesTheSession() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxUsageSectionModel()
        let capabilities: Set<String> = [SupermuxMobileCapability.usageV1.rawValue]

        let first = Task {
            await model.runSession(client: client, hostCapabilities: capabilities, connectionID: "a")
        }
        try await TestWait().until { model.store != nil }
        let firstStore = model.store
        first.cancel()
        _ = await first.value

        let second = Task {
            await model.runSession(client: client, hostCapabilities: capabilities, connectionID: "b")
        }
        try await TestWait().until { model.store !== firstStore }
        second.cancel()
        _ = await second.value

        #expect(model.store !== firstStore)
    }

    /// A disconnect hides the gauge outright: showing limits from a Mac that
    /// is no longer paired would be worse than showing nothing.
    @MainActor
    @Test func endingTheSessionHidesTheGauge() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxUsageSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [SupermuxMobileCapability.usageV1.rawValue],
                connectionID: "a"
            )
        }
        try await TestWait().until { model.store != nil }
        session.cancel()
        _ = await session.value

        model.endSession()

        #expect(model.store == nil)
        #expect(!model.showsButton)
        #expect(model.tightestWindow == nil)
    }

    /// Against an upstream Mac the session exists but the gauge stays hidden
    /// and no request is ever issued.
    @MainActor
    @Test func aSessionWithoutTheCapabilityHidesTheGaugeAndIssuesNoRequest() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxUsageSectionModel()

        await model.runSession(client: client, hostCapabilities: [], connectionID: "a")

        #expect(!model.showsButton)
        #expect(client.callLog.isEmpty)
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

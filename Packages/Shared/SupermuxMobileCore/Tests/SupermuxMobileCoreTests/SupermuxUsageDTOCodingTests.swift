import Foundation
import Testing
@testable import SupermuxMobileCore

/// Wire coverage for the usage DTOs: the snake_case shape both sides encode
/// and decode through, plus the derived accessors the phone renders from.
@Suite struct SupermuxUsageDTOCodingTests {
    // MARK: - Wire shape

    @Test func windowRoundTripsThroughSnakeCaseWireKeys() throws {
        let window = SupermuxUsageWindowDTO(
            kind: SupermuxUsageWindowDTO.weeklyKind,
            percent: 81.4,
            resetsAt: 1_700_000_000,
            aheadOfPace: true
        )
        let object = try wireObject(window)
        #expect(object["kind"] as? String == "weekly")
        #expect(object["percent"] as? Double == 81.4)
        #expect(object["resets_at"] as? Double == 1_700_000_000)
        #expect(object["ahead_of_pace"] as? Bool == true)
        // `label` is absent for non-scoped windows rather than sent as null.
        #expect(object["label"] == nil)
        #expect(try decode(SupermuxUsageWindowDTO.self, from: object) == window)
    }

    @Test func accountRoundTripsThroughSnakeCaseWireKeys() throws {
        let account = SupermuxUsageAccountDTO(
            id: "1|rajin@example.com",
            slot: 1,
            email: "rajin@example.com",
            displayName: "Rajin",
            isActive: true,
            isDisabled: false,
            status: SupermuxUsageAccountDTO.okStatus,
            windows: [SupermuxUsageWindowDTO(kind: "session", percent: 47)],
            fetchedAt: 1_699_999_000
        )
        let object = try wireObject(account)
        #expect(object["display_name"] as? String == "Rajin")
        #expect(object["is_active"] as? Bool == true)
        #expect(object["is_disabled"] as? Bool == false)
        #expect(object["fetched_at"] as? Double == 1_699_999_000)
        #expect(try decode(SupermuxUsageAccountDTO.self, from: object) == account)
    }

    @Test func providerRoundTripsThroughSnakeCaseWireKeys() throws {
        let provider = SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.readyState,
            source: SupermuxUsageProviderDTO.sessionLogSource,
            planType: "pro",
            needsRelogin: true,
            windows: [SupermuxUsageWindowDTO(kind: "session", percent: 19)],
            fetchedAt: 1_699_999_500
        )
        let object = try wireObject(provider)
        #expect(object["plan_type"] as? String == "pro")
        #expect(object["needs_relogin"] as? Bool == true)
        #expect(try decode(SupermuxUsageProviderDTO.self, from: object) == provider)
    }

    /// An older phone must not choke on a newer Mac's extra keys, and a
    /// leaner Mac payload (identity only) must still decode.
    @Test func unknownKeysAreToleratedAndOptionalsDefaultToNil() throws {
        let object: [String: Any] = [
            "kind": "scoped",
            "label": "Fable",
            "percent": 12.0,
            "future_field": ["nested": true],
        ]
        let window = try decode(SupermuxUsageWindowDTO.self, from: object)
        #expect(window.label == "Fable")
        #expect(window.resetsAt == nil)
        #expect(window.aheadOfPace == nil)

        let lean = try decode(SupermuxUsageAccountDTO.self, from: ["id": "0|"])
        #expect(lean.windows == nil)
        #expect(lean.displayWindows.isEmpty)
        // An absent status means healthy: an older Mac's leaner payload must
        // not render every account as broken.
        #expect(lean.isHealthy)
    }

    // MARK: - Derived accessors

    @Test func clampingAndSeverityMatchTheDesktopThresholds() {
        #expect(SupermuxUsageWindowDTO(kind: "session", percent: -5).clampedPercent == 0)
        #expect(SupermuxUsageWindowDTO(kind: "session", percent: 140).clampedPercent == 100)
        #expect(SupermuxUsageWindowDTO(kind: "session", percent: 69.9).severity == .normal)
        #expect(SupermuxUsageWindowDTO(kind: "session", percent: 70).severity == .warning)
        #expect(SupermuxUsageWindowDTO(kind: "session", percent: 89.9).severity == .warning)
        #expect(SupermuxUsageWindowDTO(kind: "session", percent: 90).severity == .critical)
        // Out-of-range values bucket on the CLAMPED percent, so a provider
        // reporting 140% still reads critical rather than falling through.
        #expect(SupermuxUsageWindowDTO(kind: "session", percent: 140).severity == .critical)
    }

    @Test func windowsSortSessionThenWeeklyThenScoped() {
        let windows = [
            SupermuxUsageWindowDTO(kind: "scoped", label: "Fable", percent: 30),
            SupermuxUsageWindowDTO(kind: "weekly", percent: 81),
            SupermuxUsageWindowDTO(kind: "session", percent: 47),
            SupermuxUsageWindowDTO(kind: "scoped", label: "Spark", percent: 55),
        ]
        let sorted = windows.sortedForDisplay()
        #expect(sorted.map(\.kind) == ["session", "weekly", "scoped", "scoped"])
        // Scoped windows tie on rank, so the busier one leads.
        #expect(sorted[2].label == "Spark")
        #expect(windows.tightest?.percent == 81)
    }

    @Test func activeAccountPrefersTheFlaggedRowThenTheFirst() {
        let flagged = SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.readyState,
            accounts: [
                SupermuxUsageAccountDTO(id: "1|a", isActive: false),
                SupermuxUsageAccountDTO(id: "2|b", isActive: true),
            ]
        )
        #expect(flagged.activeAccount?.id == "2|b")

        // No row flagged active (a degraded cswap payload): the first row
        // still gates the gauge rather than leaving it blank.
        let unflagged = SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.readyState,
            accounts: [
                SupermuxUsageAccountDTO(id: "1|a"),
                SupermuxUsageAccountDTO(id: "2|b"),
            ]
        )
        #expect(unflagged.activeAccount?.id == "1|a")
        #expect(SupermuxUsageProviderDTO(state: "ready").activeAccount == nil)
    }

    @Test func gaugeWindowsAreEmptyUnlessTheProviderIsReady() {
        let windows = [SupermuxUsageWindowDTO(kind: "session", percent: 47)]
        let loading = SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.loadingState,
            windows: windows
        )
        #expect(loading.gaugeWindows.isEmpty)
        let ready = SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.readyState,
            windows: windows
        )
        #expect(ready.gaugeWindows.count == 1)
        // Claude has no provider-level windows; the ACTIVE account's gate the
        // gauge, so a busier secondary account cannot inflate the ring.
        let claude = SupermuxUsageProviderDTO(
            state: SupermuxUsageProviderDTO.readyState,
            accounts: [
                SupermuxUsageAccountDTO(
                    id: "1|a",
                    isActive: true,
                    windows: [SupermuxUsageWindowDTO(kind: "session", percent: 20)]
                ),
                SupermuxUsageAccountDTO(
                    id: "2|b",
                    windows: [SupermuxUsageWindowDTO(kind: "session", percent: 99)]
                ),
            ]
        )
        #expect(claude.gaugeWindows.map(\.percent) == [20])
    }

    @Test func tightestWindowSpansBothProviders() {
        let state = SupermuxUsageStateDTO(
            claude: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                accounts: [SupermuxUsageAccountDTO(
                    id: "1|a",
                    isActive: true,
                    windows: [SupermuxUsageWindowDTO(kind: "weekly", percent: 61)]
                )]
            ),
            codex: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                windows: [SupermuxUsageWindowDTO(kind: "session", percent: 88)]
            )
        )
        #expect(state.tightestWindow?.percent == 88)
    }

    /// The footer must report the OLDEST measurement, and for Claude that is
    /// the per-account time — cswap serves cached numbers, so the snapshot's
    /// own fetch time would present stale data as fresh.
    @Test func oldestMeasurementPrefersAccountTimesOverTheFetchTime() {
        let state = SupermuxUsageStateDTO(
            claude: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                accounts: [
                    SupermuxUsageAccountDTO(id: "1|a", isActive: true, fetchedAt: 1_000),
                    SupermuxUsageAccountDTO(id: "2|b", fetchedAt: 500),
                ],
                fetchedAt: 9_000
            ),
            codex: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                fetchedAt: 2_000
            )
        )
        #expect(state.oldestMeasurementDate == Date(timeIntervalSince1970: 500))
    }

    @Test func nonReadyProvidersContributeNoMeasurementTime() {
        let state = SupermuxUsageStateDTO(
            claude: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.failedState,
                fetchedAt: 100
            ),
            codex: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                fetchedAt: 2_000
            )
        )
        #expect(state.oldestMeasurementDate == Date(timeIntervalSince1970: 2_000))
        let none = SupermuxUsageStateDTO(
            claude: SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.loadingState),
            codex: SupermuxUsageProviderDTO(state: SupermuxUsageProviderDTO.loadingState)
        )
        #expect(none.oldestMeasurementDate == nil)
        #expect(none.tightestWindow == nil)
    }

    // MARK: - Countdown

    @Test func countdownRendersTheTwoMostSignificantUnits() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(SupermuxUsageCountdown.text(until: now.addingTimeInterval(5 * 86400 + 17 * 3600), now: now) == "5d 17h")
        #expect(SupermuxUsageCountdown.text(until: now.addingTimeInterval(4 * 3600 + 39 * 60), now: now) == "4h 39m")
        #expect(SupermuxUsageCountdown.text(until: now.addingTimeInterval(12 * 60), now: now) == "12m")
        // Exact units drop the zero component.
        #expect(SupermuxUsageCountdown.text(until: now.addingTimeInterval(2 * 86400), now: now) == "2d")
        #expect(SupermuxUsageCountdown.text(until: now.addingTimeInterval(3 * 3600), now: now) == "3h")
        // Sub-minute rounds up; a past reset clamps to zero.
        #expect(SupermuxUsageCountdown.text(until: now.addingTimeInterval(30), now: now) == "1m")
        #expect(SupermuxUsageCountdown.text(until: now.addingTimeInterval(-60), now: now) == "0m")
    }

    // MARK: - Helpers

    private func wireObject(_ value: some Encodable) throws -> [String: Any] {
        try SupermuxWireJSON().dictionary(from: value)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from object: [String: Any]
    ) throws -> Value {
        try SupermuxWireJSON().decode(type, from: object)
    }
}

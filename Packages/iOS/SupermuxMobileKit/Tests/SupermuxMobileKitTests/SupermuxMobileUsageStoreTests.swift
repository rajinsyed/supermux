import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// Usage-store behavior: the capability gate, the exact `usage.state` wire
/// call, the poll loop, and the last-good-data-on-failure rule — all against
/// the fake Mac client.
@MainActor
@Suite struct SupermuxMobileUsageStoreTests {
    private let wait = TestWait()

    private static let usageCapability = SupermuxMobileCapability.usageV1.rawValue

    private func makeStore(
        client: FakeSupermuxMacClient,
        capabilities: [String] = [usageCapability],
        pollInterval: Duration = .milliseconds(5)
    ) -> SupermuxMobileUsageStore {
        SupermuxMobileUsageStore(
            client: client,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: capabilities),
            pollInterval: pollInterval,
            idleSleep: { try? await Task.sleep(for: $0) }
        )
    }

    private func readyState(
        claudePercent: Double = 47,
        codexPercent: Double = 19
    ) -> SupermuxUsageStateDTO {
        SupermuxUsageStateDTO(
            claude: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                source: SupermuxUsageProviderDTO.cswapSource,
                accounts: [SupermuxUsageAccountDTO(
                    id: "1|rajin@example.com",
                    slot: 1,
                    email: "rajin@example.com",
                    isActive: true,
                    status: SupermuxUsageAccountDTO.okStatus,
                    windows: [SupermuxUsageWindowDTO(kind: "session", percent: claudePercent)],
                    fetchedAt: 1_770_000_000
                )],
                fetchedAt: 1_770_000_000
            ),
            codex: SupermuxUsageProviderDTO(
                state: SupermuxUsageProviderDTO.readyState,
                source: "api",
                planType: "pro",
                windows: [SupermuxUsageWindowDTO(kind: "session", percent: codexPercent)],
                fetchedAt: 1_770_000_000
            )
        )
    }

    // MARK: Capability gate

    /// UI-02: against an upstream Mac the store never issues a request and
    /// the gauge stays hidden.
    @Test func loopIsInertWithoutUsageCapability() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: [])

        await store.run()
        await store.refresh()

        #expect(client.callLog.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.showsUsage == false)
        #expect(store.usage == nil)
    }

    @Test func usageCapabilityShowsTheEntryPoint() {
        let store = makeStore(client: FakeSupermuxMacClient())
        #expect(store.showsUsage)
    }

    // MARK: Wire contract

    @Test func refreshSendsTheExactUsageStateWireCall() async throws {
        let client = FakeSupermuxMacClient()
        client.usageStateResponse = readyState()
        let store = makeStore(client: client)

        await store.refresh()

        #expect(client.recordedWireCalls.count == 1)
        let call = try #require(client.recordedWireCalls.first)
        #expect(call.method == "mobile.supermux.usage.state")
        #expect(call.params.count == 0)
        #expect(store.hasLoaded)
        #expect(store.usage == readyState())
        #expect(store.lastErrorDescription == nil)
    }

    /// The gauge fills to the busier of the two providers, so a quiet Claude
    /// window cannot hide a nearly-exhausted Codex limit.
    @Test func tightestWindowSpansBothProviders() async throws {
        let client = FakeSupermuxMacClient()
        client.usageStateResponse = readyState(claudePercent: 30, codexPercent: 88)
        let store = makeStore(client: client)

        await store.refresh()

        #expect(store.tightestWindow?.percent == 88)
    }

    // MARK: Poll loop

    @Test func runLoopKeepsRefetchingUntilCancelled() async throws {
        let client = FakeSupermuxMacClient()
        client.usageStateResponse = readyState()
        let store = makeStore(client: client)

        let loop = Task { await store.run() }
        try await wait.until { client.usageStateCallCount >= 3 }
        loop.cancel()
        _ = await loop.value

        #expect(store.hasLoaded)
    }

    // MARK: Failure handling

    /// A dropped connection must not blank numbers that were true a minute
    /// ago: the last-good snapshot stays on screen beside the error.
    @Test func aFailedRefreshKeepsTheLastGoodSnapshot() async throws {
        let client = FakeSupermuxMacClient()
        client.usageStateResponse = readyState()
        let store = makeStore(client: client)
        await store.refresh()
        #expect(store.usage != nil)

        client.usageStateError = FakeUsageError.offline
        await store.refresh()

        #expect(store.usage == readyState())
        #expect(store.hasLoaded)
        #expect(store.lastErrorDescription != nil)
    }

    @Test func aSucceedingRefreshClearsThePreviousError() async throws {
        let client = FakeSupermuxMacClient()
        client.usageStateError = FakeUsageError.offline
        let store = makeStore(client: client)
        await store.refresh()
        #expect(store.lastErrorDescription != nil)
        #expect(store.hasLoaded == false)

        client.usageStateError = nil
        client.usageStateResponse = readyState()
        await store.refresh()

        #expect(store.lastErrorDescription == nil)
        #expect(store.hasLoaded)
    }

    /// Concurrent refreshes (pull-to-refresh landing on top of the poll loop)
    /// coalesce into ONE round trip rather than stacking requests.
    @Test func aRefreshInFlightSuppressesASecondRoundTrip() async throws {
        let client = FakeSupermuxMacClient()
        client.usageStateResponse = readyState()
        let gate = RPCHoldGate()
        client.usageStateHold = gate
        let store = makeStore(client: client)

        let first = Task { await store.refresh() }
        try await wait.until { gate.hasParked }
        // The store reports the in-flight pass, so the UI can show a spinner.
        #expect(store.isRefreshing)
        await store.refresh()
        gate.release()
        _ = await first.value

        #expect(client.usageStateCallCount == 1)
        #expect(store.isRefreshing == false)
    }
}

private enum FakeUsageError: Error {
    case offline
}

import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// Sessions-store behavior: the capability gate, subscribe-before-fetch, the
/// poke-driven refetch, monotonic snapshot reconcile, and the mutation paths.
@MainActor
@Suite struct SupermuxClaudeSessionsStoreTests {
    private let wait = TestWait()

    private func makeStore(
        client: FakeSupermuxMacClient,
        capabilities: [String] = ["supermux.claude.v1"]
    ) -> SupermuxClaudeSessionsStore {
        SupermuxClaudeSessionsStore(
            client: client,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: capabilities),
            idleSleep: { _ in }
        )
    }

    @Test func staysInertWithoutTheHarnessCapability() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: ["supermux.projects.v1"])
        #expect(!store.showsClaudeHarness)
        await store.refresh()
        let task = Task { await store.run() }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value
        #expect(client.claude.sessionsListCallCount == 0)
        #expect(!client.callLog.contains("events"))
    }

    /// The run loop must subscribe BEFORE its first fetch, or a poke emitted
    /// while that fetch is in flight is lost with nothing to replace it.
    @Test func subscribesBeforeTheFirstFetch() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }
        task.cancel()
        _ = await task.value

        let subscribeIndex = try #require(client.callLog.firstIndex(of: "events"))
        let fetchIndex = try #require(client.callLog.firstIndex(of: "claudeSessionsList"))
        #expect(subscribeIndex < fetchIndex)
        #expect(client.subscribedTopicSets.first == [.claudeSessionsUpdated])
    }

    @Test func aPokeRefetchesTheList() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.sessionsListResponse = SupermuxClaudeSessionsDTO(
            sessions: [FakeSupermuxClaudeScript.makeSession()],
            stateVersion: 1
        )
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }

        client.claude.sessionsListResponse = SupermuxClaudeSessionsDTO(
            sessions: [
                FakeSupermuxClaudeScript.makeSession(),
                FakeSupermuxClaudeScript.makeSession(id: "session-2", lastActivityAt: 200),
            ],
            stateVersion: 2
        )
        client.emit(SupermuxMobileEvent(topic: .claudeSessionsUpdated))
        try await wait.until { store.sessions.count == 2 }
        task.cancel()
        _ = await task.value
        #expect(store.stateVersion == 2)
    }

    /// The Mac's `state_version` is its LIVE-session revision, so it goes DOWN
    /// when a session ends. A store that refused lower versions would freeze
    /// its list permanently the first time that happened — a bug that only
    /// shows up after the feature has been used for a while, which is exactly
    /// why it is pinned here.
    @Test func aLowerStateVersionStillApplies() {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        store.apply(SupermuxClaudeSessionsDTO(
            sessions: [
                FakeSupermuxClaudeScript.makeSession(id: "a"),
                FakeSupermuxClaudeScript.makeSession(id: "ending"),
            ],
            stateVersion: 5
        ))
        store.apply(SupermuxClaudeSessionsDTO(
            sessions: [FakeSupermuxClaudeScript.makeSession(id: "a")],
            stateVersion: 4
        ))
        #expect(store.sessions.map(\.sessionID) == ["a"])
        #expect(store.stateVersion == 4)
    }

    /// Overlapping refetches can land out of order (the run loop's initial
    /// fetch racing a poke-driven one). The request generation — not the
    /// server's numbering — is what keeps the newest response authoritative.
    @Test func aSlowerEarlierFetchCannotOverwriteAFresherOne() async throws {
        let client = FakeSupermuxMacClient()
        let gate = RPCHoldGate()
        client.claude.sessionsListHold = gate
        client.claude.sessionsListResponses = [
            SupermuxClaudeSessionsDTO(
                sessions: [FakeSupermuxClaudeScript.makeSession(id: "stale")],
                stateVersion: 1
            ),
            SupermuxClaudeSessionsDTO(
                sessions: [FakeSupermuxClaudeScript.makeSession(id: "fresh")],
                stateVersion: 2
            ),
        ]
        let store = makeStore(client: client)

        // Two independent passes: `refresh()` joins an in-flight fetch, so the
        // race is driven through the private path both of them funnel into.
        let first = Task { await store.performRefreshForTesting() }
        try await wait.until { gate.hasParked }
        let second = Task { await store.performRefreshForTesting() }
        try await wait.until { client.claude.sessionsListCallCount == 2 }

        // Release the SECOND call first, then the stale first one.
        gate.release()
        gate.release()
        await first.value
        await second.value
        #expect(store.sessions.map(\.sessionID) == ["fresh"])
    }

    @Test func sessionsSortByMostRecentActivity() {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        store.apply(SupermuxClaudeSessionsDTO(
            sessions: [
                FakeSupermuxClaudeScript.makeSession(id: "old", lastActivityAt: 10),
                FakeSupermuxClaudeScript.makeSession(id: "new", lastActivityAt: 90),
                FakeSupermuxClaudeScript.makeSession(id: "never", lastActivityAt: nil),
            ],
            stateVersion: 1
        ))
        #expect(store.sessions.map(\.sessionID) == ["new", "old", "never"])
    }

    @Test func creatingASessionRefetchesAndReturnsTheMacsSnapshot() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.sessionResponse = SupermuxClaudeSessionResultDTO(
            session: FakeSupermuxClaudeScript.makeSession(id: "created")
        )
        let store = makeStore(client: client)
        let result = try await store.createSession(
            SupermuxClaudeSessionCreateRequestDTO(cwd: "/repo", launcher: .claude)
        )
        #expect(result.session.sessionID == "created")
        #expect(client.claude.sessionsListCallCount == 1)
        #expect(!store.isMutating)
    }

    /// A session that FAILED to start still comes back as a value, carrying
    /// the redacted stderr — the ccx DroidProxy path. Turning that into a
    /// thrown error would hide the one diagnostic the user needs.
    @Test func aFailedStartIsReturnedWithItsDiagnosticRatherThanThrown() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.sessionResponse = SupermuxClaudeSessionResultDTO(
            session: FakeSupermuxClaudeScript.makeSession(id: "dead", state: .failed),
            stderrExcerpt: "ccx: DroidProxy is not running"
        )
        let store = makeStore(client: client)
        let result = try await store.createSession(
            SupermuxClaudeSessionCreateRequestDTO(cwd: "/repo", launcher: .ccx)
        )
        #expect(result.session.state == .failed)
        #expect(result.stderrExcerpt == "ccx: DroidProxy is not running")
    }

    @Test func aFailedMutationRecordsAndRethrows() async {
        struct Boom: Error {}
        let client = FakeSupermuxMacClient()
        client.claude.sessionCreateError = Boom()
        let store = makeStore(client: client)
        await #expect(throws: Boom.self) {
            try await store.createSession(
                SupermuxClaudeSessionCreateRequestDTO(cwd: "/repo", launcher: .claude)
            )
        }
        #expect(store.lastErrorDescription != nil)
        #expect(!store.isMutating)
    }

    @Test func deletingASessionAlsoDropsItsLocalReadMarker() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        store.markOpened(id: "gone")
        #expect(store.openedSessionIDs.contains("gone"))
        try await store.deleteSession(id: "gone")
        #expect(!store.openedSessionIDs.contains("gone"))
    }

    @Test func resumeAndEndSendTheirContractMethods() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        _ = try await store.resumeSession(id: "s1")
        try await store.endSession(id: "s1")
        let methods = client.recordedWireCalls.map(\.method)
        #expect(methods.contains("mobile.supermux.claude.session.resume"))
        #expect(methods.contains("mobile.supermux.claude.session.end"))
    }

    // MARK: Indicators

    @Test func indicatorsFoldMacStateWithTheLocalReadMarker() {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let ended = FakeSupermuxClaudeScript.makeSession(id: "ended", state: .ended)
        #expect(store.indicator(for: ended) == .finishedUnopened)
        store.markOpened(id: "ended")
        #expect(store.indicator(for: ended) == .finished)

        #expect(
            store.indicator(for: FakeSupermuxClaudeScript.makeSession(state: .working)) == .working
        )
        #expect(
            store.indicator(for: FakeSupermuxClaudeScript.makeSession(state: .starting)) == .working
        )
        #expect(store.indicator(for: FakeSupermuxClaudeScript.makeSession(state: .idle)) == .idle)
        #expect(
            store.indicator(for: FakeSupermuxClaudeScript.makeSession(state: .failed)) == .failed
        )
    }

    /// Overlapping callers (poll, pull-to-refresh, poke) must share ONE
    /// request and all return against its settled result.
    @Test func concurrentRefreshesShareOneRequest() async throws {
        let client = FakeSupermuxMacClient()
        let gate = RPCHoldGate()
        client.claude.sessionsListHold = gate
        let store = makeStore(client: client)

        let first = Task { await store.refresh() }
        try await wait.until { gate.hasParked }
        let second = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(10))
        gate.release()
        await first.value
        await second.value
        #expect(client.claude.sessionsListCallCount == 1)
    }
}

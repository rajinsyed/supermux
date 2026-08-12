import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The Claude entry point's mount rules: the capability gate, session
/// lifetime across a navigation push, and the conversation-store cache.
@MainActor
@Suite struct SupermuxClaudeSectionModelTests {
    private let wait = TestWait()

    private let claudeCapability = SupermuxMobileCapability.claudeV1.rawValue

    private func session(id: String, state: SupermuxClaudeSessionState) -> SupermuxClaudeSessionDTO {
        SupermuxClaudeSessionDTO(
            sessionID: id,
            title: id,
            cwd: "/repo",
            launcher: .claude,
            state: state,
            cost: SupermuxClaudeCostDTO(totalUSD: 0, turns: 0, durationMS: 0),
            version: 1
        )
    }

    /// A fork phone paired with an upstream Mac must render exactly upstream's
    /// toolbar, and must never issue a harness request.
    @Test func theEntryHidesAndStaysSilentWithoutTheCapability() async {
        let client = FakeSupermuxMacClient()
        let model = SupermuxClaudeSectionModel()
        let task = Task {
            await model.runSession(
                client: client,
                hostCapabilities: ["supermux.projects.v1"],
                connectionID: "c1"
            )
        }
        _ = await task.value
        #expect(!model.showsEntry)
        #expect(!client.callLog.contains("claudeSessionsList"))
        #expect(!client.callLog.contains("claudeOptions"))
    }

    @Test func theEntryShowsWithTheCapability() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxClaudeSectionModel()
        let task = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [claudeCapability],
                connectionID: "c1"
            )
        }
        try await wait.until { model.showsEntry }
        task.cancel()
        _ = await task.value
    }

    /// A navigation push cancels the driver's task. The store must SURVIVE it,
    /// or reopening the sheet flashes an empty list and re-subscribes.
    @Test func cancellationKeepsTheStoreSoAPopResumes() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxClaudeSectionModel()
        let task = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [claudeCapability],
                connectionID: "c1"
            )
        }
        try await wait.until { model.store != nil }
        let first = model.store
        task.cancel()
        _ = await task.value
        #expect(model.store != nil)

        // Same connection: the same store is reused rather than replaced.
        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [claudeCapability],
                connectionID: "c1"
            )
        }
        try await wait.until { model.store != nil }
        #expect(model.store === first)
        resumed.cancel()
        _ = await resumed.value
    }

    /// A reconnect (or capabilities arriving late) must REPLACE the store, so
    /// the model never drives a dead client.
    @Test func aNewConnectionReplacesTheStoreAndOptions() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxClaudeSectionModel()
        let first = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [claudeCapability],
                connectionID: "c1"
            )
        }
        try await wait.until { model.store != nil }
        let firstStore = model.store
        first.cancel()
        _ = await first.value

        let second = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [claudeCapability],
                connectionID: "c2"
            )
        }
        try await wait.until { model.store !== firstStore }
        #expect(model.store !== firstStore)
        second.cancel()
        _ = await second.value
    }

    @Test func endingTheSessionDropsEverything() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxClaudeSectionModel()
        let task = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [claudeCapability],
                connectionID: "c1"
            )
        }
        try await wait.until { model.store != nil }
        task.cancel()
        _ = await task.value
        model.endSession()
        #expect(model.store == nil)
        #expect(model.options == nil)
        #expect(!model.showsEntry)
    }

    @Test func theBadgeCountsOnlyRunningSessions() async throws {
        let client = FakeSupermuxMacClient()
        client.claudeSessions = SupermuxClaudeSessionsDTO(
            sessions: [
                session(id: "a", state: .working),
                session(id: "b", state: .starting),
                session(id: "c", state: .idle),
                session(id: "d", state: .ended),
            ],
            stateVersion: 1
        )
        let model = SupermuxClaudeSectionModel()
        let task = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [claudeCapability],
                connectionID: "c1"
            )
        }
        try await wait.until { model.workingCount == 2 }
        task.cancel()
        _ = await task.value
    }

    /// `navigationDestination`'s builder runs on every body evaluation, so a
    /// store constructed there would restart the transcript subscription on
    /// unrelated redraws.
    @Test func theConversationStoreIsCachedPerSession() {
        let client = FakeSupermuxMacClient()
        let store = SupermuxClaudeSessionsStore(
            client: client,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: [claudeCapability])
        )
        let first = store.conversationStore(for: "s1")
        #expect(store.conversationStore(for: "s1") === first)

        let other = store.conversationStore(for: "s2")
        #expect(other !== first)
        #expect(other.sessionID == "s2")
    }
}

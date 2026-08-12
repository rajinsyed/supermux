import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// Conversation-store behavior: transcript merge semantics, the event
/// ordering rule, gap recovery from history, and the watch lease.
@MainActor
@Suite struct SupermuxClaudeConversationStoreTests {
    private let wait = TestWait()

    private func makeStore(
        client: FakeSupermuxMacClient,
        capabilities: [String] = ["supermux.claude.v1"],
        sessionID: String = "session-1"
    ) -> SupermuxClaudeConversationStore {
        SupermuxClaudeConversationStore(
            client: client,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: capabilities),
            sessionID: sessionID,
            idleSleep: { _ in },
            heartbeatSleep: { _ in try? await Task.sleep(for: .milliseconds(50)) }
        )
    }

    private func frame(
        _ eventNo: UInt64,
        _ event: SupermuxClaudeChatEvent,
        session: String = "session-1"
    ) -> SupermuxMobileEvent {
        SupermuxMobileEvent(
            topic: .claudeEvent,
            claudeFrame: SupermuxClaudeEventFrame(
                sessionID: session,
                eventNo: eventNo,
                frame: event
            )
        )
    }

    // MARK: Transcript value semantics

    @Test func mergeIsIdempotentAndKeepsSequenceOrder() {
        var transcript = SupermuxClaudeTranscript()
        transcript.merge([
            FakeSupermuxClaudeScript.makeMessage(id: "b", seq: 2),
            FakeSupermuxClaudeScript.makeMessage(id: "a", seq: 1),
        ])
        #expect(transcript.messages.map(\.id) == ["a", "b"])

        // Re-delivering an existing id REPLACES it: this is what lets a
        // re-anchor overlap the frames that triggered it without duplicating.
        transcript.merge([FakeSupermuxClaudeScript.makeMessage(id: "a", seq: 1, text: "edited")])
        #expect(transcript.messages.count == 2)
        #expect(transcript.messages.first?.text == "edited")
    }

    @Test func replaceAndPrependTrackThePagingCursor() {
        var transcript = SupermuxClaudeTranscript()
        transcript.replace(
            with: [FakeSupermuxClaudeScript.makeMessage(id: "c", seq: 30)],
            hasMore: true
        )
        #expect(transcript.oldestSeq == 30)
        #expect(transcript.hasMoreHistory)

        transcript.prepend([FakeSupermuxClaudeScript.makeMessage(id: "a", seq: 10)], hasMore: false)
        #expect(transcript.messages.map(\.id) == ["a", "c"])
        #expect(transcript.oldestSeq == 10)
        #expect(!transcript.hasMoreHistory)
    }

    // MARK: The ordering rule

    @Test func frameDispositionFollowsTheMonotonicRule() {
        #expect(supermuxClaudeFrameDisposition(eventNo: 5, lastAppliedEventNo: 4) == .apply)
        #expect(supermuxClaudeFrameDisposition(eventNo: 4, lastAppliedEventNo: 4) == .duplicate)
        #expect(supermuxClaudeFrameDisposition(eventNo: 2, lastAppliedEventNo: 4) == .duplicate)
        #expect(supermuxClaudeFrameDisposition(eventNo: 7, lastAppliedEventNo: 4) == .reanchor)
        // Nothing anchored yet, and an undecodable payload, both re-anchor.
        #expect(supermuxClaudeFrameDisposition(eventNo: 1, lastAppliedEventNo: nil) == .reanchor)
        #expect(supermuxClaudeFrameDisposition(eventNo: nil, lastAppliedEventNo: 4) == .reanchor)
    }

    // MARK: Run loop

    @Test func staysInertWithoutTheHarnessCapability() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: ["supermux.projects.v1"])
        let task = Task { await store.run() }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value
        #expect(client.claude.historyCallCount == 0)
        #expect(client.claude.watchCalls.isEmpty)
    }

    @Test func subscribesBeforeAnchoringFromHistory() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.historyPage = SupermuxClaudeHistoryPageDTO(
            messages: [FakeSupermuxClaudeScript.makeMessage(id: "m1", seq: 1)],
            hasMore: false
        )
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }
        task.cancel()
        _ = await task.value

        let subscribeIndex = try #require(client.callLog.firstIndex(of: "events"))
        let historyIndex = try #require(client.callLog.firstIndex(of: "claudeHistory"))
        #expect(subscribeIndex < historyIndex)
        #expect(client.subscribedTopicSets.first == [.claudeEvent, .claudeSessionsUpdated])
        #expect(store.transcript.messages.map(\.id) == ["m1"])
    }

    /// The first frame after an anchor always re-anchors (history carries no
    /// event number), and then consecutive frames apply directly.
    @Test func consecutiveFramesApplyAfterTheFirstAnchor() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }
        let anchorHistoryCalls = client.claude.historyCallCount

        client.emit(frame(10, .append([FakeSupermuxClaudeScript.makeMessage(id: "m10", seq: 10)])))
        try await wait.until { store.transcript.messages.contains { $0.id == "m10" } }
        #expect(client.claude.historyCallCount == anchorHistoryCalls + 1)

        client.emit(frame(11, .append([FakeSupermuxClaudeScript.makeMessage(id: "m11", seq: 11)])))
        try await wait.until { store.transcript.messages.contains { $0.id == "m11" } }
        // No further history fetch: 11 followed 10 exactly.
        #expect(client.claude.historyCallCount == anchorHistoryCalls + 1)
        task.cancel()
        _ = await task.value
    }

    /// A skipped event number must re-anchor from history rather than leave a
    /// silent hole in the transcript.
    @Test func aGapReanchorsFromHistory() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }

        client.emit(frame(1, .append([FakeSupermuxClaudeScript.makeMessage(id: "m1", seq: 1)])))
        try await wait.until { store.transcript.messages.contains { $0.id == "m1" } }
        let beforeGap = client.claude.historyCallCount
        let reanchorsBefore = store.reanchorCount

        // The Mac's authoritative view already contains the message the
        // dropped frames carried.
        client.claude.historyPage = SupermuxClaudeHistoryPageDTO(
            messages: [
                FakeSupermuxClaudeScript.makeMessage(id: "m1", seq: 1),
                FakeSupermuxClaudeScript.makeMessage(id: "m2", seq: 2),
                FakeSupermuxClaudeScript.makeMessage(id: "m3", seq: 3),
            ],
            hasMore: false
        )
        client.emit(frame(9, .append([FakeSupermuxClaudeScript.makeMessage(id: "m9", seq: 9)])))
        try await wait.until { store.reanchorCount == reanchorsBefore + 1 }
        try await wait.until { store.transcript.messages.contains { $0.id == "m9" } }
        #expect(client.claude.historyCallCount > beforeGap)
        // The recovered page AND the triggering frame are both present, with
        // no duplicate of the overlapping message.
        #expect(store.transcript.messages.map(\.id) == ["m1", "m2", "m3", "m9"])
        task.cancel()
        _ = await task.value
    }

    /// A FAILED re-anchor must not adopt the triggering frame's number: the
    /// hole it was repairing is still open, and advancing the anchor would
    /// make every later consecutive frame look gapless while events stay
    /// permanently missing. The anchor stays nil, so the next frame retries
    /// the authoritative reload — and recovers once history works again.
    @Test func aFailedReanchorDoesNotAdoptTheFrameNumber() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }

        client.emit(frame(4, .append([FakeSupermuxClaudeScript.makeMessage(id: "m4", seq: 4)])))
        try await wait.until { store.transcript.messages.contains { $0.id == "m4" } }
        let reanchorsBefore = store.reanchorCount

        // Events 5-6 are lost; the gap frame arrives while history is DOWN.
        client.claude.historyError = URLError(.networkConnectionLost)
        client.emit(frame(7, .append([FakeSupermuxClaudeScript.makeMessage(id: "m7", seq: 7)])))
        try await wait.until { store.reanchorCount == reanchorsBefore + 1 }

        // History recovers, carrying the messages the lost events held. The
        // NEXT frame — consecutive with the rejected one — must still be
        // treated as a gap and re-anchor, not applied as if nothing happened.
        client.claude.historyError = nil
        client.claude.historyPage = SupermuxClaudeHistoryPageDTO(
            messages: (4...7).map { FakeSupermuxClaudeScript.makeMessage(id: "m\($0)", seq: UInt64($0)) },
            hasMore: false
        )
        client.emit(frame(8, .append([FakeSupermuxClaudeScript.makeMessage(id: "m8", seq: 8)])))
        try await wait.until { store.transcript.messages.contains { $0.id == "m8" } }
        #expect(store.reanchorCount == reanchorsBefore + 2)
        #expect(store.transcript.messages.map(\.id) == ["m4", "m5", "m6", "m7", "m8"])
        task.cancel()
        _ = await task.value
    }

    @Test func aDuplicateFrameIsIgnored() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }

        client.emit(frame(4, .append([FakeSupermuxClaudeScript.makeMessage(id: "m4", seq: 4)])))
        try await wait.until { store.transcript.messages.contains { $0.id == "m4" } }
        let historyCalls = client.claude.historyCallCount
        let reanchors = store.reanchorCount

        client.emit(frame(4, .append([FakeSupermuxClaudeScript.makeMessage(id: "dupe", seq: 4)])))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!store.transcript.messages.contains { $0.id == "dupe" })
        #expect(client.claude.historyCallCount == historyCalls)
        #expect(store.reanchorCount == reanchors)
        task.cancel()
        _ = await task.value
    }

    /// Frames for OTHER sessions ride the same Mac-wide topic and must not
    /// disturb this store's anchor.
    @Test func framesForOtherSessionsAreIgnored() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }
        let reanchors = store.reanchorCount

        client.emit(frame(
            99,
            .append([FakeSupermuxClaudeScript.makeMessage(id: "other", seq: 99)]),
            session: "session-2"
        ))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!store.transcript.messages.contains { $0.id == "other" })
        #expect(store.reanchorCount == reanchors)
        task.cancel()
        _ = await task.value
    }

    /// An undecodable frame has no session id, so it cannot be filtered out.
    /// Treating it as a gap is the safe reading.
    @Test func anUndecodableFrameReanchors() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }
        let reanchors = store.reanchorCount

        client.emit(SupermuxMobileEvent(topic: .claudeEvent, claudeFrame: nil))
        try await wait.until { store.reanchorCount == reanchors + 1 }
        task.cancel()
        _ = await task.value
    }

    @Test func aStateFrameMovesTheWorkingIndicator() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.sessionResponse = SupermuxClaudeSessionResultDTO(
            session: FakeSupermuxClaudeScript.makeSession(state: .idle)
        )
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.session != nil }
        #expect(!store.isWorking)

        client.emit(frame(1, .state(.working)))
        try await wait.until { store.isWorking }
        task.cancel()
        _ = await task.value
    }

    @Test func olderHistoryPagesPrependAndStopAtTheEnd() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.historyPage = SupermuxClaudeHistoryPageDTO(
            messages: [FakeSupermuxClaudeScript.makeMessage(id: "m5", seq: 5)],
            hasMore: true
        )
        client.claude.olderHistoryPages = [
            SupermuxClaudeHistoryPageDTO(
                messages: [FakeSupermuxClaudeScript.makeMessage(id: "m1", seq: 1)],
                hasMore: false
            ),
        ]
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { store.hasLoaded }

        await store.loadOlderHistory()
        #expect(store.transcript.messages.map(\.id) == ["m1", "m5"])
        #expect(!store.transcript.hasMoreHistory)

        // With no more pages the store must not keep asking.
        let calls = client.claude.historyCallCount
        await store.loadOlderHistory()
        #expect(client.claude.historyCallCount == calls)
        task.cancel()
        _ = await task.value
    }

    // MARK: Watch lease

    @Test func theWatchLeaseIsAcquiredAndReleasedWithOneClientID() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        let task = Task { await store.run() }
        try await wait.until { client.claude.watchCalls.contains { $0.enable } }
        task.cancel()
        _ = await task.value
        try await wait.until { client.claude.watchCalls.contains { !$0.enable } }

        let ids = Set(client.claude.watchCalls.map(\.clientID))
        #expect(ids.count == 1)
        #expect(client.claude.watchCalls.first?.enable == true)
        #expect(client.claude.watchCalls.last?.enable == false)
    }

    // MARK: Mutations

    /// Send-while-working relies on the MAC's queue: the phone reports the
    /// queue position it was given and keeps no queue of its own.
    @Test func sendReportsTheMacsQueueDecision() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.sendResponse = SupermuxClaudeSendResultDTO(queued: true, queuePosition: 2)
        let store = makeStore(client: client)
        let result = try await store.send(text: "next")
        #expect(result.queued)
        #expect(result.queuePosition == 2)
        let call = try #require(client.recordedWireCalls.last)
        #expect(call.method == "mobile.supermux.claude.send")
        #expect(call.params["text"] as? String == "next")
    }

    /// The RECONCILED value is what the store adopts — Claude may resolve a
    /// requested model to something else, and echoing the request back would
    /// make the pill lie about what is running.
    @Test func setOptionAdoptsTheReconciledValue() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.setOptionResponse = SupermuxClaudeSetOptionResultDTO(
            appliedValue: .string("claude-opus-4-6")
        )
        let store = makeStore(client: client)
        let applied = try await store.setOption(.model, to: .string("opus"))
        #expect(applied == .string("claude-opus-4-6"))
    }

    @Test func interruptSendsTheControlMethod() async throws {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client)
        try await store.interrupt()
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.claude.interrupt")
    }

    @Test func toolPayloadFollowsTheChunkCursorToEOF() async throws {
        let client = FakeSupermuxMacClient()
        client.claude.toolPayloadChunks = [
            try SupermuxClaudeToolPayloadChunkDTO(
                data: Data("abc".utf8),
                offset: 0,
                totalSize: 6,
                eof: false
            ),
            try SupermuxClaudeToolPayloadChunkDTO(
                data: Data("def".utf8),
                offset: 3,
                totalSize: 6,
                eof: true
            ),
        ]
        let store = makeStore(client: client)
        let payload = try await store.toolPayload(messageID: "m1")
        #expect(String(decoding: payload, as: UTF8.self) == "abcdef")
        let offsets = client.recordedWireCalls
            .filter { $0.method == "mobile.supermux.claude.tool_payload" }
            .map { $0.params["offset"] as? Int64 }
        #expect(offsets == [0, 3])
    }
}

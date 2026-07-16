import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-04 for commit/sync/history: store state transitions correctly on
/// commit / generate-and-commit / push / pull / stash / stash-pop / history
/// actions, with the exact m3-f2 wire shapes asserted against the fake's
/// recording, an extended RPC deadline on push/pull, and user-visible states
/// for the `ai_unavailable` and push-failure error paths.
@MainActor
@Suite struct SupermuxMobileChangesStoreSyncTests {
    private static let workspaceID = "7B1D4C22-9F3A-4E0D-B7A1-5C6E8F0A2D33"

    private static let status = SupermuxChangesStatusDTO(
        workspaceId: workspaceID,
        isRepository: true,
        branch: "main",
        upstreamBranch: "origin/main",
        ahead: 1,
        behind: 0,
        staged: [SupermuxChangedFileDTO(path: "staged.txt", kind: "added")],
        unstaged: [],
        untracked: [],
        stashCount: 1
    )

    private static let changesOnly = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.changesV1.rawValue]
    )

    private func makeStore(fake: FakeSupermuxMacClient) -> SupermuxMobileChangesStore {
        SupermuxMobileChangesStore(
            client: fake,
            capabilities: Self.changesOnly,
            workspaceID: Self.workspaceID,
            idleSleep: { _ in await Task.yield() },
            heartbeatSleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
    }

    // MARK: Commit

    @Test func commitSendsTheExactWireCallClearsTheDraftAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        fake.changesCommitResponse = SupermuxChangesCommitResponse(
            sha: "aabbccddeeff00112233445566778899aabbccdd"
        )
        let store = makeStore(fake: fake)

        store.commitMessage = "  feat: mobile commit  "
        await store.commit()

        // §2 exact wire shape: trimmed message, stage_all omitted when false.
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.commit")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "message": "feat: mobile commit",
        ] as NSDictionary)
        // Success: the sha surfaces briefly, the draft clears, and the store
        // refetches so the sections move without waiting for the Mac's poke.
        #expect(store.lastCommitShortSha == "aabbccd")
        #expect(store.commitMessage.isEmpty)
        #expect(fake.changesStatusCallCount == 1)
        #expect(!store.isMutating)
        // The loaded history page is now stale.
        #expect(store.historyEpoch == 1)
        #expect(!store.hasLoadedHistory)
    }

    @Test func commitWithStageAllSendsStageAllTrue() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        let store = makeStore(fake: fake)

        store.commitMessage = "feat: everything"
        await store.commit(stageAll: true)
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "message": "feat: everything",
            "stage_all": true,
        ] as NSDictionary)
    }

    @Test func commitWithABlankMessageIsANoOp() async throws {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(fake: fake)

        store.commitMessage = "   \n "
        await store.commit()
        #expect(fake.recordedWireCalls.isEmpty)
        #expect(store.lastCommitShortSha == nil)
    }

    @Test func commitFailureSurfacesTheErrorAndPreservesTheDraft() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesCommitError = MobileShellConnectionError.rpcError(
            "unavailable", "Nothing to commit"
        )
        let store = makeStore(fake: fake)

        store.commitMessage = "feat: doomed"
        await store.commit()
        #expect(store.lastErrorDescription != nil)
        #expect(store.commitMessage == "feat: doomed")
        #expect(store.lastCommitShortSha == nil)
        // No refetch after a failed mutation, and the store unblocks.
        #expect(fake.changesStatusCallCount == 0)
        #expect(!store.isMutating)
        #expect(store.historyEpoch == 0)
    }

    // MARK: Generate & Commit

    @Test func generateAndCommitGeneratesThenCommitsWithTheGeneratedMessage() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        fake.generateCommitMessageResponse = SupermuxChangesGeneratedMessageResponse(
            message: "feat: add commit flow"
        )
        let store = makeStore(fake: fake)

        await store.generateAndCommit()

        // Generation strictly precedes the commit.
        let generateIndex = try #require(fake.callLog.firstIndex(of: "changesGenerateCommitMessage"))
        let commitIndex = try #require(fake.callLog.firstIndex(of: "changesCommit"))
        #expect(generateIndex < commitIndex)
        // §2 exact wire shapes for both calls.
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.generate_commit_message")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
        ] as NSDictionary)
        #expect(fake.recordedWireCalls[1].method == "mobile.supermux.changes.commit")
        #expect(fake.recordedWireCalls[1].params == [
            "workspace_id": Self.workspaceID,
            "message": "feat: add commit flow",
        ] as NSDictionary)
        #expect(store.lastCommitShortSha == "aabbccd")
        #expect(store.commitMessage.isEmpty)
        #expect(!store.isGeneratingMessage)
    }

    @Test func generateAndCommitSurfacesAIUnavailableAndDoesNotCommit() async throws {
        let fake = FakeSupermuxMacClient()
        fake.generateCommitMessageError = MobileShellConnectionError.rpcError(
            "ai_unavailable", "No AI Gateway key is configured"
        )
        let store = makeStore(fake: fake)

        await store.generateAndCommit()
        // The server's message surfaces on the dedicated AI notice (the
        // screen wraps it in a friendly localized headline), NOT on the
        // generic error row, and nothing was committed.
        #expect(store.aiUnavailableNotice == "No AI Gateway key is configured")
        #expect(store.lastErrorDescription == nil)
        #expect(!fake.callLog.contains("changesCommit"))
        #expect(!store.isGeneratingMessage)
        #expect(!store.isMutating)
    }

    @Test func generateAndCommitSurfacesOtherGenerationFailuresOnTheErrorRow() async throws {
        let fake = FakeSupermuxMacClient()
        fake.generateCommitMessageError = MobileShellConnectionError.rpcError(
            "unavailable", "Nothing to commit"
        )
        let store = makeStore(fake: fake)

        await store.generateAndCommit()
        #expect(store.aiUnavailableNotice == nil)
        #expect(store.lastErrorDescription != nil)
        #expect(!fake.callLog.contains("changesCommit"))
    }

    @Test func aNewGenerationAttemptClearsTheStaleAINotice() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        fake.generateCommitMessageError = MobileShellConnectionError.rpcError(
            "ai_unavailable", "No AI Gateway key is configured"
        )
        let store = makeStore(fake: fake)

        await store.generateAndCommit()
        #expect(store.aiUnavailableNotice != nil)

        fake.generateCommitMessageError = nil
        await store.generateAndCommit()
        #expect(store.aiUnavailableNotice == nil)
    }

    @Test func generateAndCommitWaitsForAnInFlightMutationInsteadOfSilentlyDroppingTheCommit() async throws {
        // Reproduces the m3-f2 bug: generation starts (isMutating stays
        // false), a stage lands WHILE generation is still in flight
        // (isMutating flips true), and generation finishes before the stage
        // does. The final commit must never hit `commit()`'s mutation gate
        // and silently no-op — it must wait for the stage, then commit.
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        fake.generateCommitMessageResponse = SupermuxChangesGeneratedMessageResponse(
            message: "feat: generated while a stage was in flight"
        )
        fake.changesGenerateCommitMessageShouldHold = true
        fake.changesStageShouldHold = true
        let store = makeStore(fake: fake)

        let generateTask = Task { await store.generateAndCommit() }
        try await TestWait().until { fake.callLog.contains("changesGenerateCommitMessage") }
        #expect(store.isGeneratingMessage)
        #expect(!store.isMutating, "generation alone must not set isMutating")

        // A stage lands mid-generation and is still on the wire.
        let stageTask = Task { await store.stage(paths: ["src/app.swift"]) }
        try await TestWait().until { fake.callLog.contains("changesStage") }
        #expect(store.isMutating)

        // Generation completes while the stage is still in flight.
        fake.changesGenerateCommitMessageGate.release()
        try await TestWait().until { !store.isGeneratingMessage }
        // The commit must NOT have fired yet — it must be waiting for the
        // mutation slot, not silently dropping.
        for _ in 0..<20 { await Task.yield() }
        #expect(!fake.callLog.contains("changesCommit"), "must wait for the in-flight stage, not fire early")

        // The stage finally completes, freeing the mutation slot.
        fake.changesStageGate.release()
        await stageTask.value
        await generateTask.value

        // The commit must still have landed — never a silent drop.
        #expect(fake.callLog.contains("changesCommit"))
        #expect(store.commitMessage.isEmpty)
        #expect(store.lastCommitShortSha != nil)
    }

    @Test func commitNeverClearsThePriorConfirmationWhenItNoOpsAgainstAnInFlightMutation() async throws {
        // The store's OWN reentrancy guard (not generateAndCommit's wait):
        // a `commit()` call that no-ops against an in-flight mutation must
        // never wipe a PRIOR confirmation — before the fix,
        // `lastCommitShortSha` was cleared unconditionally BEFORE the
        // mutation guard, wiping it even when nothing new committed.
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        fake.changesCommitResponse = SupermuxChangesCommitResponse(sha: "1111111111111111111111111111111111aaaa")
        let store = makeStore(fake: fake)

        // An earlier commit already landed and left its confirmation
        // visible.
        store.commitMessage = "feat: already committed"
        await store.commit()
        #expect(store.lastCommitShortSha == "1111111")

        // Occupy the mutation slot with a held stage so a concurrent commit
        // attempt hits `mutate`'s reentrancy guard.
        fake.changesStageShouldHold = true
        let stageTask = Task { await store.stage(paths: ["a.txt"]) }
        try await TestWait().until { fake.callLog.contains("changesStage") }
        #expect(store.isMutating)

        store.commitMessage = "feat: second, while a stage is in flight"
        await store.commit()
        #expect(store.lastCommitShortSha == "1111111", "the no-op commit must not wipe the prior confirmation")
        #expect(
            fake.callLog.filter { $0 == "changesCommit" }.count == 1,
            "the second attempt must not have committed"
        )

        fake.changesStageGate.release()
        await stageTask.value
    }

    // MARK: Push / pull

    @Test func pushSendsTheExactWireCallWithAnExtendedDeadlineAndReturnsTheLog() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        fake.changesPushResponse = SupermuxChangesSyncResponse(
            ok: true,
            logLines: ["To file:///tmp/remote", "abc1234..def5678  main -> main"]
        )
        let store = makeStore(fake: fake)

        let entry = try #require(await store.push())
        #expect(entry.operation == .push)
        #expect(entry.lines == ["To file:///tmp/remote", "abc1234..def5678  main -> main"])
        #expect(!entry.truncated)
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.push")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
        ] as NSDictionary)
        // m3-f2: the Mac's git network timeout is 120 s, so the phone must
        // extend its default 30 s deadline to >= 130 s for push/pull.
        let timeout = try #require(fake.recordedSyncTimeouts.first)
        #expect(timeout.method == "mobile.supermux.changes.push")
        #expect((timeout.timeoutNanoseconds ?? 0) >= 130_000_000_000)
        // Refetch + history invalidation (is_pushed styling shifted).
        #expect(fake.changesStatusCallCount == 1)
        #expect(store.historyEpoch == 1)
        #expect(store.activeSyncOperation == nil)
    }

    @Test func pushFailureSurfacesTheErrorAndReturnsNil() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesPushError = MobileShellConnectionError.rpcError(
            "unavailable", "fatal: could not read from remote repository"
        )
        let store = makeStore(fake: fake)

        let entry = await store.push()
        #expect(entry == nil)
        #expect(store.lastErrorDescription != nil)
        #expect(fake.changesStatusCallCount == 0)
        #expect(!store.isMutating)
        #expect(store.activeSyncOperation == nil)
        #expect(store.historyEpoch == 0)
    }

    @Test func pullSendsTheExactWireCallWithAnExtendedDeadlineAndReturnsTheLog() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        fake.changesPullResponse = SupermuxChangesSyncResponse(
            ok: true,
            logLines: ["Updating abc1234..def5678", "Fast-forward"],
            logTruncated: true
        )
        let store = makeStore(fake: fake)

        let entry = try #require(await store.pull())
        #expect(entry.operation == .pull)
        #expect(entry.lines == ["Updating abc1234..def5678", "Fast-forward"])
        #expect(entry.truncated)
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.pull")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
        ] as NSDictionary)
        let timeout = try #require(fake.recordedSyncTimeouts.first)
        #expect((timeout.timeoutNanoseconds ?? 0) >= 130_000_000_000)
        #expect(fake.changesStatusCallCount == 1)
    }

    // MARK: Stash

    @Test func stashAndStashPopSendTheExactWireCallsAndRefetch() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.status
        let store = makeStore(fake: fake)

        await store.stash()
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.stash")
        // `message` is omitted when absent.
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
        ] as NSDictionary)

        await store.stashPop()
        // recordedWireCalls[1] is the status refetch after the stash.
        let popCall = try #require(
            fake.recordedWireCalls.first { $0.method == "mobile.supermux.changes.stash_pop" }
        )
        #expect(popCall.params == [
            "workspace_id": Self.workspaceID,
        ] as NSDictionary)
        #expect(fake.changesStatusCallCount == 2)
        #expect(!store.isMutating)
    }

    @Test func stashRequestCarriesOptionalMessageAndIncludeUntrackedOnlyWhenSet() throws {
        let bare = SupermuxChangesStashRequest(workspaceID: Self.workspaceID)
        #expect(bare.wireParams as NSDictionary == [
            "workspace_id": Self.workspaceID,
        ] as NSDictionary)

        let full = SupermuxChangesStashRequest(
            workspaceID: Self.workspaceID,
            message: "wip: from phone",
            includeUntracked: true
        )
        #expect(full.wireParams as NSDictionary == [
            "workspace_id": Self.workspaceID,
            "message": "wip: from phone",
            "include_untracked": true,
        ] as NSDictionary)
    }

    // MARK: History pagination

    @Test func historyLoadsTheFirstPageThenPaginatesWithTheCursor() async throws {
        let fake = FakeSupermuxMacClient()
        let local3 = SupermuxCommitDTO(sha: String(repeating: "3", count: 40), subject: "Local 3", isPushed: false)
        let local2 = SupermuxCommitDTO(sha: String(repeating: "2", count: 40), subject: "Local 2", isPushed: false)
        let pushed = SupermuxCommitDTO(sha: String(repeating: "1", count: 40), subject: "Pushed", isPushed: true)
        let incoming = SupermuxCommitDTO(sha: String(repeating: "9", count: 40), subject: "Incoming", isPushed: true)
        fake.changesHistoryResponses = [
            SupermuxChangesHistoryResponse(
                commits: [local3, local2],
                incoming: [incoming],
                nextCursor: local2.sha
            ),
            SupermuxChangesHistoryResponse(commits: [pushed]),
        ]
        let store = makeStore(fake: fake)

        await store.loadHistoryIfNeeded()
        // §2 exact first-page wire shape: limit and cursor both omitted.
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.history")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
        ] as NSDictionary)
        #expect(store.historyCommits == [local3, local2])
        #expect(store.incomingCommits == [incoming])
        #expect(store.historyNextCursor == local2.sha)
        #expect(store.hasLoadedHistory)
        #expect(!store.isLoadingHistory)

        // Loaded pages are cached: a repeat if-needed load is a no-op.
        await store.loadHistoryIfNeeded()
        #expect(fake.recordedWireCalls.count == 1)

        // The next page passes the cursor back verbatim and appends.
        await store.loadMoreHistory()
        #expect(fake.recordedWireCalls[1].params == [
            "workspace_id": Self.workspaceID,
            "cursor": local2.sha,
        ] as NSDictionary)
        #expect(store.historyCommits == [local3, local2, pushed])
        #expect(store.incomingCommits == [incoming])
        #expect(store.historyNextCursor == nil)

        // No cursor left: load-more is a no-op.
        await store.loadMoreHistory()
        #expect(fake.recordedWireCalls.count == 2)
    }

    @Test func historyFailureSurfacesItsOwnErrorAndAllowsARetry() async throws {
        struct Down: Error {}
        let fake = FakeSupermuxMacClient()
        fake.changesHistoryError = Down()
        let store = makeStore(fake: fake)

        await store.loadHistoryIfNeeded()
        #expect(store.historyErrorDescription != nil)
        #expect(!store.hasLoadedHistory)
        #expect(!store.isLoadingHistory)

        fake.changesHistoryError = nil
        fake.changesHistoryResponses = [
            SupermuxChangesHistoryResponse(commits: [SupermuxCommitDTO(sha: String(repeating: "a", count: 40))])
        ]
        await store.loadHistoryIfNeeded()
        #expect(store.historyErrorDescription == nil)
        #expect(store.hasLoadedHistory)
        #expect(store.historyCommits.count == 1)
    }

    // MARK: Response wire decoding (snake_case + unknown-field tolerance)

    @Test func syncResponsesDecodeFromWireJSON() throws {
        let commitJSON = Data(#"{"sha":"abc123","future_field":1}"#.utf8)
        let commit = try JSONDecoder().decode(SupermuxChangesCommitResponse.self, from: commitJSON)
        #expect(commit.sha == "abc123")

        let messageJSON = Data(#"{"message":"feat: x","future_field":true}"#.utf8)
        let message = try JSONDecoder().decode(
            SupermuxChangesGeneratedMessageResponse.self, from: messageJSON
        )
        #expect(message.message == "feat: x")

        let syncJSON = Data(#"{"ok":true,"log_lines":["a","b"],"log_truncated":true,"future_field":"x"}"#.utf8)
        let sync = try JSONDecoder().decode(SupermuxChangesSyncResponse.self, from: syncJSON)
        #expect(sync.ok == true)
        #expect(sync.logLines == ["a", "b"])
        #expect(sync.logTruncated == true)

        let historyJSON = Data("""
        {"commits":[{"sha":"abc","short_sha":"abc","is_pushed":false}],
         "incoming":[],"next_cursor":"abc","future_field":{}}
        """.utf8)
        let history = try JSONDecoder().decode(SupermuxChangesHistoryResponse.self, from: historyJSON)
        #expect(history.commits?.count == 1)
        #expect(history.commits?.first?.isPushed == false)
        #expect(history.incoming?.isEmpty == true)
        #expect(history.nextCursor == "abc")
    }
}

import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// A scripted, call-recording ``SupermuxMacCalling`` for store tests: no
/// transport, no Mac. Main-actor so tests can mutate scripted responses and
/// read the recorded calls without data races.
@MainActor
final class FakeSupermuxMacClient: SupermuxMacCalling {
    /// The response the next `projectsList()` call returns.
    var listResponse = SupermuxProjectsListResponse(projects: [])
    /// When set, `projectsList()` throws instead of returning.
    var listError: (any Error)?
    /// Scripted `projectIcon` responses consumed in FIFO order.
    var iconResponses: [SupermuxProjectIconResponse] = []
    /// When set, `projectIcon` throws instead of returning.
    var iconError: (any Error)?

    /// The response the next `worktreesList` call returns.
    var worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [])
    /// When set, `worktreesList` throws instead of returning.
    var worktreesListError: (any Error)?
    /// The response the next `worktreeSuggestBranch` call returns.
    var suggestBranchResponse = SupermuxBranchSuggestionResponse(
        branchName: "cheerful-umbrella",
        source: "random"
    )
    /// When set, `worktreeSuggestBranch` throws instead of returning.
    var suggestBranchError: (any Error)?
    /// The response the next `worktreeCreate` call returns.
    var worktreeCreateResponse = SupermuxWorktreeCreateResponse()
    /// When set, `worktreeCreate` throws instead of returning.
    var worktreeCreateError: (any Error)?
    /// The response the next `worktreeOpen` call returns.
    var worktreeOpenResponse = SupermuxWorktreeOpenResponse()
    /// When set, `worktreeOpen` throws instead of returning.
    var worktreeOpenError: (any Error)?
    /// When set, `worktreeRemove` throws instead of returning.
    var worktreeRemoveError: (any Error)?

    /// The response the next `projectCreate`/`projectUpdate` call returns.
    var projectWriteResponse = SupermuxProjectWriteResponse(
        project: SupermuxProjectDTO(id: "", name: "", rootPath: "")
    )
    /// When set, `projectCreate`/`projectUpdate` throws instead of returning.
    var projectWriteError: (any Error)?
    /// When set, `projectDelete` throws instead of returning.
    var projectDeleteError: (any Error)?
    /// When set, `projectsSetSectionCollapsed` throws instead of returning.
    var sectionCollapsedError: (any Error)?
    /// The response the next `presetCreate`/`presetUpdate` call returns.
    var presetWriteResponse = SupermuxPresetWriteResponse(
        preset: SupermuxTerminalPresetDTO(id: "", name: "", command: "")
    )
    /// When set, `presetCreate`/`presetUpdate` throws instead of returning.
    var presetWriteError: (any Error)?
    /// When set, `presetDelete` throws instead of returning.
    var presetDeleteError: (any Error)?

    /// The response the next `changesStatus` call returns.
    var changesStatusResponse = SupermuxChangesStatusDTO()
    /// When set, `changesStatus` throws instead of returning.
    var changesStatusError: (any Error)?
    /// The response the next `changesDiff` call returns.
    var changesDiffResponse = SupermuxDiffDTO(path: "")
    /// When set, `changesDiff` throws instead of returning.
    var changesDiffError: (any Error)?
    /// When set, `changesWatch` throws instead of returning.
    var changesWatchError: (any Error)?
    /// When set, `changesStage` throws instead of returning.
    var changesStageError: (any Error)?
    /// When set, `changesUnstage` throws instead of returning.
    var changesUnstageError: (any Error)?
    /// When set, `changesDiscard` throws instead of returning.
    var changesDiscardError: (any Error)?
    /// The response the next `changesCommit` call returns.
    var changesCommitResponse = SupermuxChangesCommitResponse(
        sha: "aabbccddeeff00112233445566778899aabbccdd"
    )
    /// When set, `changesCommit` throws instead of returning.
    var changesCommitError: (any Error)?
    /// The response the next `changesGenerateCommitMessage` call returns.
    var generateCommitMessageResponse = SupermuxChangesGeneratedMessageResponse(
        message: "feat: generated message"
    )
    /// When set, `changesGenerateCommitMessage` throws instead of returning.
    var generateCommitMessageError: (any Error)?
    /// The response the next `changesPush` call returns.
    var changesPushResponse = SupermuxChangesSyncResponse(ok: true, logLines: [])
    /// When set, `changesPush` throws instead of returning.
    var changesPushError: (any Error)?
    /// The response the next `changesPull` call returns.
    var changesPullResponse = SupermuxChangesSyncResponse(ok: true, logLines: [])
    /// When set, `changesPull` throws instead of returning.
    var changesPullError: (any Error)?
    /// When set, `changesStash` throws instead of returning.
    var changesStashError: (any Error)?
    /// When set, `changesStashPop` throws instead of returning.
    var changesStashPopError: (any Error)?
    /// Scripted `changesHistory` responses consumed in FIFO order (an empty
    /// queue answers an empty page).
    var changesHistoryResponses: [SupermuxChangesHistoryResponse] = []
    /// When set, `changesHistory` throws instead of returning.
    var changesHistoryError: (any Error)?

    /// One-shot hold flag: the NEXT `changesStatus` call parks on
    /// ``changesStatusGate`` (after snapshotting its response) until
    /// released — scripts an out-of-order response race for the
    /// request-generation guard test (#5).
    var changesStatusShouldHoldNextCall = false
    /// The park/release gate for a held `changesStatus` call.
    let changesStatusGate = RPCHoldGate()

    /// When true, every `changesStage` call parks on ``changesStageGate``
    /// until released — scripts a mutation-still-in-flight race for the
    /// `generateAndCommit()` no-silent-drop test (#1).
    var changesStageShouldHold = false
    let changesStageGate = RPCHoldGate()

    /// When true, every `changesGenerateCommitMessage` call parks on
    /// ``changesGenerateCommitMessageGate`` until released (#1).
    var changesGenerateCommitMessageShouldHold = false
    let changesGenerateCommitMessageGate = RPCHoldGate()

    /// Extra latency applied ONLY to `changesWatch {enable:false}` calls —
    /// lets a test prove a stale disable is still delivered in its correct
    /// enqueue order (before a fresher enable), never racing ahead due to
    /// being slow (#6).
    var changesWatchDisableArtificialDelay: Duration?

    /// The response the next `runState` call returns.
    var runStateResponse = SupermuxRunStateResponse(runs: [])
    /// When set, `runState` throws instead of returning.
    var runStateError: (any Error)?
    /// The response the next `runStart` call returns; `nil` synthesizes a
    /// running row for the requested project.
    var runStartResponse: SupermuxRunWriteResponse?
    /// When set, `runStart` throws instead of returning.
    var runStartError: (any Error)?
    /// The response the next `runStop` call returns; `nil` synthesizes an
    /// idle row for the requested project.
    var runStopResponse: SupermuxRunWriteResponse?
    /// When set, `runStop` throws instead of returning.
    var runStopError: (any Error)?
    /// The response the next `presetLaunch` call returns.
    var presetLaunchResponse = SupermuxPresetLaunchResponse()
    /// When set, `presetLaunch` throws instead of returning.
    var presetLaunchError: (any Error)?
    /// The response the next `actionRun` call returns.
    var actionRunResponse = SupermuxActionRunResponse(ok: true, kind: "command")
    /// When set, `actionRun` throws instead of returning.
    var actionRunError: (any Error)?

    /// The files fixture tree the fake serves AND mutates: root-relative
    /// directory path ("" = root) → its listing. Create/rename/duplicate/
    /// trash edit the tree, so a store's refetch-after-op observes the
    /// mutation like a real Mac (UI-05).
    var filesTree: [String: [SupermuxFileEntryDTO]] = [:]
    /// When set, `filesList` throws instead of returning.
    var filesListError: (any Error)?
    /// When set, `filesCreate` throws instead of returning.
    var filesCreateError: (any Error)?
    /// When set, `filesRename` throws instead of returning.
    var filesRenameError: (any Error)?
    /// When set, `filesDuplicate` throws instead of returning.
    var filesDuplicateError: (any Error)?
    /// When set, `filesTrash` throws instead of returning.
    var filesTrashError: (any Error)?

    /// Ordered log of every seam call, for ordering assertions
    /// (e.g. subscribe-before-fetch).
    private(set) var callLog: [String] = []
    private(set) var projectsListCallCount = 0
    private(set) var runStateCallCount = 0
    private(set) var worktreesListCallCount = 0
    private(set) var changesStatusCallCount = 0
    private(set) var iconRequests: [(projectID: String, etag: String?)] = []
    private(set) var subscribedTopicSets: [Set<SupermuxMobileTopic>] = []
    /// Exact wire method + params of every worktree request, in call order —
    /// the UI-03 "recorded calls match §2 exactly" evidence.
    private(set) var recordedWireCalls: [(method: String, params: NSDictionary)] = []
    /// Per-request RPC deadline overrides observed at the seam, in call order
    /// — the m3-f2 "push/pull need >= 130 s" evidence.
    private(set) var recordedSyncTimeouts: [(method: String, timeoutNanoseconds: UInt64?)] = []

    private var eventContinuations: [AsyncStream<SupermuxMobileEvent>.Continuation] = []

    // MARK: Recording seams
    //
    // The per-namespace method groups live in FakeSupermuxMacClient+Changes/
    // +Run/+Files.swift (file-length budget). The recorded storage stays
    // `private(set)`, so those extension files record through these helpers.

    /// Appends one call to the ordered log.
    func record(_ call: String) {
        callLog.append(call)
    }

    /// Appends one call to the ordered log AND its exact wire method+params
    /// to the recorded wire calls.
    func record(_ call: String, method: String, params: [String: Any]) {
        callLog.append(call)
        recordedWireCalls.append((method, params as NSDictionary))
    }

    /// Like ``record(_:method:params:)``, additionally recording the
    /// request's per-RPC deadline override (the m3-f2 sync-timeout evidence).
    func record(
        _ call: String,
        method: String,
        params: [String: Any],
        syncTimeoutNanoseconds: UInt64?
    ) {
        record(call, method: method, params: params)
        recordedSyncTimeouts.append((method, syncTimeoutNanoseconds))
    }

    /// Bumps the `changes.status` call counter (mutated from +Changes.swift).
    func countChangesStatusCall() {
        changesStatusCallCount += 1
    }

    /// Snapshots the current `changesStatus` response for THIS call (so a
    /// later-changed `changesStatusResponse` cannot retroactively change
    /// what an already-in-flight call returns), then parks it if
    /// ``changesStatusShouldHoldNextCall`` is set — consumed one-shot, so
    /// only the call that arrived while the flag was set holds. Called from
    /// +Changes.swift.
    func changesStatusResponseForCurrentCall() async -> SupermuxChangesStatusDTO {
        let response = changesStatusResponse
        if changesStatusShouldHoldNextCall {
            changesStatusShouldHoldNextCall = false
            await changesStatusGate.park()
        }
        return response
    }

    /// Bumps the `run.state` call counter (mutated from +Run.swift).
    func countRunStateCall() {
        runStateCallCount += 1
    }

    // MARK: Projects / worktrees / presets

    func projectsList() async throws -> SupermuxProjectsListResponse {
        callLog.append("projectsList")
        projectsListCallCount += 1
        if let listError { throw listError }
        return listResponse
    }

    func projectIcon(projectID: String, etag: String?) async throws -> SupermuxProjectIconResponse {
        callLog.append("projectIcon")
        iconRequests.append((projectID: projectID, etag: etag))
        if let iconError { throw iconError }
        guard !iconResponses.isEmpty else {
            throw FakeSupermuxMacClientError.unscriptedIconRequest
        }
        return iconResponses.removeFirst()
    }

    func worktreesList(_ request: SupermuxWorktreesListRequest) async throws -> SupermuxWorktreesListResponse {
        callLog.append("worktreesList")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let worktreesListError { throw worktreesListError }
        worktreesListCallCount += 1
        return worktreesListResponse
    }

    func worktreeSuggestBranch(
        _ request: SupermuxWorktreeSuggestBranchRequest
    ) async throws -> SupermuxBranchSuggestionResponse {
        callLog.append("worktreeSuggestBranch")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let suggestBranchError { throw suggestBranchError }
        return suggestBranchResponse
    }

    func worktreeCreate(_ request: SupermuxWorktreeCreateRequest) async throws -> SupermuxWorktreeCreateResponse {
        callLog.append("worktreeCreate")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let worktreeCreateError { throw worktreeCreateError }
        return worktreeCreateResponse
    }

    func worktreeOpen(_ request: SupermuxWorktreeOpenRequest) async throws -> SupermuxWorktreeOpenResponse {
        callLog.append("worktreeOpen")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let worktreeOpenError { throw worktreeOpenError }
        return worktreeOpenResponse
    }

    func worktreeRemove(_ request: SupermuxWorktreeRemoveRequest) async throws -> SupermuxWorktreeRemoveResponse {
        callLog.append("worktreeRemove")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let worktreeRemoveError { throw worktreeRemoveError }
        return SupermuxWorktreeRemoveResponse(removed: true, worktreePath: request.worktreePath)
    }

    func projectCreate(_ request: SupermuxProjectCreateRequest) async throws -> SupermuxProjectWriteResponse {
        callLog.append("projectCreate")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let projectWriteError { throw projectWriteError }
        return projectWriteResponse
    }

    func projectUpdate(_ request: SupermuxProjectUpdateRequest) async throws -> SupermuxProjectWriteResponse {
        callLog.append("projectUpdate")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let projectWriteError { throw projectWriteError }
        return projectWriteResponse
    }

    func projectDelete(_ request: SupermuxProjectDeleteRequest) async throws -> SupermuxProjectDeleteResponse {
        callLog.append("projectDelete")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let projectDeleteError { throw projectDeleteError }
        return SupermuxProjectDeleteResponse(removed: true, projectId: request.projectID)
    }

    func projectsSetSectionCollapsed(
        _ request: SupermuxProjectsSetSectionCollapsedRequest
    ) async throws -> SupermuxSectionCollapsedResponse {
        callLog.append("projectsSetSectionCollapsed")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let sectionCollapsedError { throw sectionCollapsedError }
        return SupermuxSectionCollapsedResponse(sectionCollapsed: request.collapsed)
    }

    func presetCreate(_ request: SupermuxPresetCreateRequest) async throws -> SupermuxPresetWriteResponse {
        callLog.append("presetCreate")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let presetWriteError { throw presetWriteError }
        return presetWriteResponse
    }

    func presetUpdate(_ request: SupermuxPresetUpdateRequest) async throws -> SupermuxPresetWriteResponse {
        callLog.append("presetUpdate")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let presetWriteError { throw presetWriteError }
        return presetWriteResponse
    }

    func presetDelete(_ request: SupermuxPresetDeleteRequest) async throws -> SupermuxPresetDeleteResponse {
        callLog.append("presetDelete")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let presetDeleteError { throw presetDeleteError }
        return SupermuxPresetDeleteResponse(removed: true, presetId: request.presetID)
    }

    // MARK: Events

    func events(topics: Set<SupermuxMobileTopic>) async -> AsyncStream<SupermuxMobileEvent> {
        callLog.append("events")
        subscribedTopicSets.append(topics)
        let (stream, continuation) = AsyncStream<SupermuxMobileEvent>.makeStream()
        eventContinuations.append(continuation)
        return stream
    }

    /// Pushes one event to every live subscriber.
    func emit(_ event: SupermuxMobileEvent) {
        for continuation in eventContinuations {
            continuation.yield(event)
        }
    }

    /// Finishes every live event stream, simulating a connection drop.
    func finishEventStreams() {
        let continuations = eventContinuations
        eventContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }
}

enum FakeSupermuxMacClientError: Error {
    case unscriptedIconRequest
}

/// A reusable FIFO parking gate for scripting deterministic response-order
/// races against a fake RPC seam: ``park()`` suspends the caller until a
/// matching ``release()`` runs, letting a test control exactly when a
/// scripted call "returns" relative to other in-flight calls.
@MainActor
final class RPCHoldGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// Suspends the caller until ``release()`` is called once for it.
    func park() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            continuations.append(continuation)
        }
    }

    /// Resumes the oldest parked caller, if any.
    func release() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    /// Whether any caller is currently parked.
    var hasParked: Bool { !continuations.isEmpty }
}

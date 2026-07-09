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

    /// Ordered log of every seam call, for ordering assertions
    /// (e.g. subscribe-before-fetch).
    private(set) var callLog: [String] = []
    private(set) var projectsListCallCount = 0
    private(set) var worktreesListCallCount = 0
    private(set) var changesStatusCallCount = 0
    private(set) var iconRequests: [(projectID: String, etag: String?)] = []
    private(set) var subscribedTopicSets: [Set<SupermuxMobileTopic>] = []
    /// Exact wire method + params of every worktree request, in call order —
    /// the UI-03 "recorded calls match §2 exactly" evidence.
    private(set) var recordedWireCalls: [(method: String, params: NSDictionary)] = []

    private var eventContinuations: [AsyncStream<SupermuxMobileEvent>.Continuation] = []

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

    func changesWatch(_ request: SupermuxChangesWatchRequest) async throws -> SupermuxChangesWatchResponse {
        callLog.append("changesWatch")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let changesWatchError { throw changesWatchError }
        return SupermuxChangesWatchResponse(watching: request.enable, ttlSeconds: 120)
    }

    func changesStatus(_ request: SupermuxChangesStatusRequest) async throws -> SupermuxChangesStatusDTO {
        callLog.append("changesStatus")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let changesStatusError { throw changesStatusError }
        changesStatusCallCount += 1
        return changesStatusResponse
    }

    func changesDiff(_ request: SupermuxChangesDiffRequest) async throws -> SupermuxDiffDTO {
        callLog.append("changesDiff")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let changesDiffError { throw changesDiffError }
        return changesDiffResponse
    }

    func changesStage(_ request: SupermuxChangesStageRequest) async throws -> SupermuxChangesAckResponse {
        callLog.append("changesStage")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let changesStageError { throw changesStageError }
        return SupermuxChangesAckResponse(ok: true)
    }

    func changesUnstage(_ request: SupermuxChangesUnstageRequest) async throws -> SupermuxChangesAckResponse {
        callLog.append("changesUnstage")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let changesUnstageError { throw changesUnstageError }
        return SupermuxChangesAckResponse(ok: true)
    }

    func changesDiscard(_ request: SupermuxChangesDiscardRequest) async throws -> SupermuxChangesAckResponse {
        callLog.append("changesDiscard")
        recordedWireCalls.append((request.wireMethod, request.wireParams as NSDictionary))
        if let changesDiscardError { throw changesDiscardError }
        return SupermuxChangesAckResponse(ok: true)
    }

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

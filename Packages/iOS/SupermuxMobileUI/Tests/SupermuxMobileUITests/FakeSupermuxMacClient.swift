import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// A scripted, call-recording ``SupermuxMacCalling`` for section-model tests:
/// no transport, no Mac. Main-actor so tests can mutate scripted responses and
/// read the recorded calls without data races. Mirrors the fake established by
/// `SupermuxMobileKitTests`.
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

    /// Ordered log of every seam call, for ordering assertions.
    private(set) var callLog: [String] = []
    private(set) var projectsListCallCount = 0
    private(set) var worktreesListCallCount = 0
    private(set) var iconRequests: [(projectID: String, etag: String?)] = []
    private(set) var subscribedTopicSets: [Set<SupermuxMobileTopic>] = []
    /// Exact wire method + params of every worktree request, in call order.
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

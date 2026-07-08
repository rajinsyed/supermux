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

    /// Ordered log of every seam call, for ordering assertions.
    private(set) var callLog: [String] = []
    private(set) var projectsListCallCount = 0
    private(set) var iconRequests: [(projectID: String, etag: String?)] = []
    private(set) var subscribedTopicSets: [Set<SupermuxMobileTopic>] = []

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

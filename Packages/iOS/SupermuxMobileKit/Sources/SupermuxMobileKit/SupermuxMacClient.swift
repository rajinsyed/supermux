public import CmuxMobileRPC
import Foundation
public import SupermuxMobileCore

/// The production ``SupermuxMacCalling``: a thin adapter over the paired
/// Mac's multiplexed RPC connection.
///
/// Requests go through `MobileCoreRPCClient.sendRequest` (which owns auth,
/// timeouts, and reconnect policy) and decode the result frame into the
/// typed responses; events ride the shared `mobile.events.subscribe`
/// pub/sub plane exactly like `MobileChatEventSource`. No state lives here
/// — everything above this seam tests against a fake.
public struct SupermuxMacClient: SupermuxMacCalling {
    private let client: MobileCoreRPCClient

    /// Creates the adapter.
    /// - Parameter client: The connected RPC client for the paired Mac.
    public init(client: MobileCoreRPCClient) {
        self.client = client
    }

    public func projectsList() async throws -> SupermuxProjectsListResponse {
        let request = try MobileCoreRPCClient.requestData(
            method: SupermuxMobileMethod.projectsList.rawValue
        )
        let result = try await client.sendRequest(request)
        return try JSONDecoder().decode(SupermuxProjectsListResponse.self, from: result)
    }

    public func projectIcon(projectID: String, etag: String?) async throws -> SupermuxProjectIconResponse {
        var params: [String: Any] = ["project_id": projectID]
        if let etag {
            params["etag"] = etag
        }
        return try await send(method: SupermuxMobileMethod.projectIcon.rawValue, params: params)
    }

    public func worktreesList(_ request: SupermuxWorktreesListRequest) async throws -> SupermuxWorktreesListResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func worktreeSuggestBranch(
        _ request: SupermuxWorktreeSuggestBranchRequest
    ) async throws -> SupermuxBranchSuggestionResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func worktreeCreate(_ request: SupermuxWorktreeCreateRequest) async throws -> SupermuxWorktreeCreateResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func worktreeOpen(_ request: SupermuxWorktreeOpenRequest) async throws -> SupermuxWorktreeOpenResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func worktreeRemove(_ request: SupermuxWorktreeRemoveRequest) async throws -> SupermuxWorktreeRemoveResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func projectCreate(_ request: SupermuxProjectCreateRequest) async throws -> SupermuxProjectWriteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func projectUpdate(_ request: SupermuxProjectUpdateRequest) async throws -> SupermuxProjectWriteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func projectDelete(_ request: SupermuxProjectDeleteRequest) async throws -> SupermuxProjectDeleteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func projectsSetSectionCollapsed(
        _ request: SupermuxProjectsSetSectionCollapsedRequest
    ) async throws -> SupermuxSectionCollapsedResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func presetCreate(_ request: SupermuxPresetCreateRequest) async throws -> SupermuxPresetWriteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func presetUpdate(_ request: SupermuxPresetUpdateRequest) async throws -> SupermuxPresetWriteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func presetDelete(_ request: SupermuxPresetDeleteRequest) async throws -> SupermuxPresetDeleteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesWatch(_ request: SupermuxChangesWatchRequest) async throws -> SupermuxChangesWatchResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesStatus(_ request: SupermuxChangesStatusRequest) async throws -> SupermuxChangesStatusDTO {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesDiff(_ request: SupermuxChangesDiffRequest) async throws -> SupermuxDiffDTO {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesStage(_ request: SupermuxChangesStageRequest) async throws -> SupermuxChangesAckResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesUnstage(_ request: SupermuxChangesUnstageRequest) async throws -> SupermuxChangesAckResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesDiscard(_ request: SupermuxChangesDiscardRequest) async throws -> SupermuxChangesAckResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesCommit(_ request: SupermuxChangesCommitRequest) async throws -> SupermuxChangesCommitResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesGenerateCommitMessage(
        _ request: SupermuxChangesGenerateCommitMessageRequest
    ) async throws -> SupermuxChangesGeneratedMessageResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesPush(_ request: SupermuxChangesPushRequest) async throws -> SupermuxChangesSyncResponse {
        try await send(
            method: request.wireMethod,
            params: request.wireParams,
            timeoutNanoseconds: request.rpcTimeoutNanoseconds
        )
    }

    public func changesPull(_ request: SupermuxChangesPullRequest) async throws -> SupermuxChangesSyncResponse {
        try await send(
            method: request.wireMethod,
            params: request.wireParams,
            timeoutNanoseconds: request.rpcTimeoutNanoseconds
        )
    }

    public func changesStash(_ request: SupermuxChangesStashRequest) async throws -> SupermuxChangesSyncResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesStashPop(_ request: SupermuxChangesStashPopRequest) async throws -> SupermuxChangesSyncResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func changesHistory(_ request: SupermuxChangesHistoryRequest) async throws -> SupermuxChangesHistoryResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func runState(_ request: SupermuxRunStateRequest) async throws -> SupermuxRunStateResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func runStart(_ request: SupermuxRunStartRequest) async throws -> SupermuxRunWriteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func runStop(_ request: SupermuxRunStopRequest) async throws -> SupermuxRunWriteResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func presetLaunch(_ request: SupermuxPresetLaunchRequest) async throws -> SupermuxPresetLaunchResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    public func actionRun(_ request: SupermuxActionRunRequest) async throws -> SupermuxActionRunResponse {
        try await send(method: request.wireMethod, params: request.wireParams)
    }

    /// Sends one request and decodes the result frame into the typed
    /// response — the single wire path every typed method funnels through.
    ///
    /// - Parameters:
    ///   - method: The wire method string.
    ///   - params: The wire params.
    ///   - timeoutNanoseconds: Optional per-request RPC deadline override
    ///     (additive: `nil` keeps the runtime default, so pre-existing calls
    ///     are unchanged). Push/pull pass their extended deadline here.
    private func send<Response: Decodable>(
        method: String,
        params: [String: Any],
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> Response {
        let request = try MobileCoreRPCClient.requestData(method: method, params: params)
        let result = try await client.sendRequest(request, timeoutNanoseconds: timeoutNanoseconds)
        return try JSONDecoder().decode(Response.self, from: result)
    }

    /// Opens the live event stream for the given `supermux.*` topics.
    ///
    /// Registers server-side AFTER the local listener exists so no event
    /// falls between subscribe and handshake; a failed handshake finishes
    /// the stream (the server never feeds an unregistered connection). The
    /// stream also finishes when the connection drops; store run loops
    /// resubscribe. Consumer cancellation withdraws the server-side
    /// registration.
    public func events(topics: Set<SupermuxMobileTopic>) async -> AsyncStream<SupermuxMobileEvent> {
        let topicStrings = topics.map(\.rawValue).sorted()
        let envelopes = await client.subscribe(to: Set(topicStrings))
        let client = self.client
        let streamID = UUID().uuidString
        return AsyncStream { continuation in
            let pump = Task {
                do {
                    let subscribe = try MobileCoreRPCClient.requestData(
                        method: "mobile.events.subscribe",
                        params: [
                            "topics": topicStrings,
                            "stream_id": streamID,
                        ]
                    )
                    _ = try await client.sendRequest(subscribe)
                } catch {
                    continuation.finish()
                    return
                }
                for await envelope in envelopes {
                    guard let event = SupermuxMobileEvent(
                        topic: envelope.topic,
                        payloadJSON: envelope.payloadJSON
                    ) else { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                pump.cancel()
                // Withdraw the server-side registration only on consumer
                // cancellation; a `.finished` means the connection died and
                // an unsubscribe would reopen a torn-down transport.
                guard case .cancelled = reason else { return }
                Task {
                    if let unsubscribe = try? MobileCoreRPCClient.requestData(
                        method: "mobile.events.unsubscribe",
                        params: ["stream_id": streamID]
                    ) {
                        _ = try? await client.sendRequest(unsubscribe)
                    }
                }
            }
        }
    }
}

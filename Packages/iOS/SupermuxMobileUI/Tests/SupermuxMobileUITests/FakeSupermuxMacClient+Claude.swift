import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The `mobile.supermux.claude.*` seam methods for this package's fake.
///
/// This package's fake exists for SCREEN tests, so the harness methods answer
/// scripted values with no queueing or gating: the store-level ordering, gap,
/// and lease behavior is covered in `SupermuxMobileKit`'s own tests against
/// the richer fake there. Duplicating that scripting here would mean two
/// fakes to keep in sync for no extra coverage.
extension FakeSupermuxMacClient {
    func claudeSessionsList(
        _ request: SupermuxClaudeSessionsListRequest
    ) async throws -> SupermuxClaudeSessionsListResponse {
        recordClaude("claudeSessionsList", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return claudeSessions
    }

    func claudeSessionCreate(
        _ request: SupermuxClaudeSessionCreateRequest
    ) async throws -> SupermuxClaudeSessionResponse {
        recordClaude("claudeSessionCreate", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return claudeSessionResult
    }

    func claudeSessionGet(
        _ request: SupermuxClaudeSessionGetRequest
    ) async throws -> SupermuxClaudeSessionResponse {
        recordClaude("claudeSessionGet", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return claudeSessionResult
    }

    func claudeSessionResume(
        _ request: SupermuxClaudeSessionResumeRequest
    ) async throws -> SupermuxClaudeSessionResponse {
        recordClaude("claudeSessionResume", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return claudeSessionResult
    }

    func claudeSessionEnd(
        _ request: SupermuxClaudeSessionEndRequest
    ) async throws -> SupermuxClaudeAcknowledgementResponse {
        recordClaude("claudeSessionEnd", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return SupermuxClaudeAcknowledgementDTO(acknowledged: true)
    }

    func claudeSessionDelete(
        _ request: SupermuxClaudeSessionDeleteRequest
    ) async throws -> SupermuxClaudeAcknowledgementResponse {
        recordClaude("claudeSessionDelete", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return SupermuxClaudeAcknowledgementDTO(acknowledged: true)
    }

    func claudeSend(_ request: SupermuxClaudeSendRequest) async throws -> SupermuxClaudeSendResponse {
        recordClaude("claudeSend", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return SupermuxClaudeSendResultDTO(queued: false)
    }

    func claudeInterrupt(
        _ request: SupermuxClaudeInterruptRequest
    ) async throws -> SupermuxClaudeAcknowledgementResponse {
        recordClaude("claudeInterrupt", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return SupermuxClaudeAcknowledgementDTO(acknowledged: true)
    }

    func claudeSetOption(
        _ request: SupermuxClaudeSetOptionRequest
    ) async throws -> SupermuxClaudeSetOptionResponse {
        recordClaude("claudeSetOption", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return SupermuxClaudeSetOptionResultDTO(appliedValue: request.body.value)
    }

    func claudeOptions(
        _ request: SupermuxClaudeOptionsRequest
    ) async throws -> SupermuxClaudeOptionsResponse {
        recordClaude("claudeOptions", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return claudeOptionsResponse
    }

    func claudeHistory(
        _ request: SupermuxClaudeHistoryRequest
    ) async throws -> SupermuxClaudeHistoryResponse {
        recordClaude("claudeHistory", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return claudeHistoryPage
    }

    func claudeToolPayload(
        _ request: SupermuxClaudeToolPayloadRequest
    ) async throws -> SupermuxClaudeToolPayloadResponse {
        recordClaude("claudeToolPayload", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return try SupermuxClaudeToolPayloadChunkDTO(
            data: claudeToolPayloadData,
            offset: 0,
            totalSize: Int64(claudeToolPayloadData.count),
            eof: true
        )
    }

    func claudeWatch(_ request: SupermuxClaudeWatchRequest) async throws -> SupermuxClaudeWatchResponse {
        recordClaude("claudeWatch", request.wireMethod, request.wireParams)
        if let error = claudeError { throw error }
        return SupermuxClaudeWatchResultDTO(enabled: request.enable)
    }
}

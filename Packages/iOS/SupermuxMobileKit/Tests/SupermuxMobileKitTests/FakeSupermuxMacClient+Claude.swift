import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The `mobile.supermux.claude.*` seam methods for the shared fake.
///
/// Scripted state lives in ``FakeSupermuxClaudeScript`` (a stored property on
/// the fake) so this extension only needs the recording helpers, keeping both
/// files inside the fork's file-length budget.
extension FakeSupermuxMacClient {
    func claudeSessionsList(
        _ request: SupermuxClaudeSessionsListRequest
    ) async throws -> SupermuxClaudeSessionsListResponse {
        record("claudeSessionsList", method: request.wireMethod, params: request.wireParams)
        claude.sessionsListCallCount += 1
        await claude.sessionsListHold?.park()
        if let error = claude.sessionsListError { throw error }
        if claude.sessionsListResponses.isEmpty { return claude.sessionsListResponse }
        return claude.sessionsListResponses.removeFirst()
    }

    func claudeSessionCreate(
        _ request: SupermuxClaudeSessionCreateRequest
    ) async throws -> SupermuxClaudeSessionResponse {
        record("claudeSessionCreate", method: request.wireMethod, params: request.wireParams)
        if let error = claude.sessionCreateError { throw error }
        return claude.sessionResponse
    }

    func claudeSessionGet(
        _ request: SupermuxClaudeSessionGetRequest
    ) async throws -> SupermuxClaudeSessionResponse {
        record("claudeSessionGet", method: request.wireMethod, params: request.wireParams)
        claude.sessionGetCallCount += 1
        if let error = claude.sessionGetError { throw error }
        return claude.sessionResponse
    }

    func claudeSessionResume(
        _ request: SupermuxClaudeSessionResumeRequest
    ) async throws -> SupermuxClaudeSessionResponse {
        record("claudeSessionResume", method: request.wireMethod, params: request.wireParams)
        if let error = claude.sessionResumeError { throw error }
        return claude.sessionResponse
    }

    func claudeSessionEnd(
        _ request: SupermuxClaudeSessionEndRequest
    ) async throws -> SupermuxClaudeAcknowledgementResponse {
        record("claudeSessionEnd", method: request.wireMethod, params: request.wireParams)
        if let error = claude.sessionEndError { throw error }
        return SupermuxClaudeAcknowledgementDTO(acknowledged: true)
    }

    func claudeSessionDelete(
        _ request: SupermuxClaudeSessionDeleteRequest
    ) async throws -> SupermuxClaudeAcknowledgementResponse {
        record("claudeSessionDelete", method: request.wireMethod, params: request.wireParams)
        if let error = claude.sessionDeleteError { throw error }
        return SupermuxClaudeAcknowledgementDTO(acknowledged: true)
    }

    func claudeSend(_ request: SupermuxClaudeSendRequest) async throws -> SupermuxClaudeSendResponse {
        record("claudeSend", method: request.wireMethod, params: request.wireParams)
        if let error = claude.sendError { throw error }
        return claude.sendResponse
    }

    func claudeInterrupt(
        _ request: SupermuxClaudeInterruptRequest
    ) async throws -> SupermuxClaudeAcknowledgementResponse {
        record("claudeInterrupt", method: request.wireMethod, params: request.wireParams)
        if let error = claude.interruptError { throw error }
        return SupermuxClaudeAcknowledgementDTO(acknowledged: true)
    }

    func claudeSetOption(
        _ request: SupermuxClaudeSetOptionRequest
    ) async throws -> SupermuxClaudeSetOptionResponse {
        record("claudeSetOption", method: request.wireMethod, params: request.wireParams)
        if let error = claude.setOptionError { throw error }
        return claude.setOptionResponse
    }

    func claudeOptions(
        _ request: SupermuxClaudeOptionsRequest
    ) async throws -> SupermuxClaudeOptionsResponse {
        record("claudeOptions", method: request.wireMethod, params: request.wireParams)
        if let error = claude.optionsError { throw error }
        return claude.optionsResponse
    }

    func claudeHistory(
        _ request: SupermuxClaudeHistoryRequest
    ) async throws -> SupermuxClaudeHistoryResponse {
        record("claudeHistory", method: request.wireMethod, params: request.wireParams)
        claude.historyCallCount += 1
        if let error = claude.historyError { throw error }
        if request.body.beforeSeq != nil, !claude.olderHistoryPages.isEmpty {
            return claude.olderHistoryPages.removeFirst()
        }
        if claude.historyPages.isEmpty { return claude.historyPage }
        return claude.historyPages.removeFirst()
    }

    func claudeToolPayload(
        _ request: SupermuxClaudeToolPayloadRequest
    ) async throws -> SupermuxClaudeToolPayloadResponse {
        record("claudeToolPayload", method: request.wireMethod, params: request.wireParams)
        if let error = claude.toolPayloadError { throw error }
        guard !claude.toolPayloadChunks.isEmpty else {
            return try SupermuxClaudeToolPayloadChunkDTO(
                data: Data(),
                offset: 0,
                totalSize: 0,
                eof: true
            )
        }
        return claude.toolPayloadChunks.removeFirst()
    }

    func claudeWatch(_ request: SupermuxClaudeWatchRequest) async throws -> SupermuxClaudeWatchResponse {
        record("claudeWatch", method: request.wireMethod, params: request.wireParams)
        claude.watchCalls.append((request.enable, request.clientID))
        if let error = claude.watchError { throw error }
        return SupermuxClaudeWatchResultDTO(enabled: request.enable, leaseExpiresAt: nil)
    }
}

/// Scripted responses and recorded calls for the Claude harness seam.
@MainActor
final class FakeSupermuxClaudeScript {
    /// The response the next `claudeSessionsList` call returns when
    /// ``sessionsListResponses`` is exhausted.
    var sessionsListResponse = SupermuxClaudeSessionsDTO(sessions: [], stateVersion: 1)
    /// Scripted `claudeSessionsList` responses, consumed in FIFO order.
    var sessionsListResponses: [SupermuxClaudeSessionsDTO] = []
    /// When set, `claudeSessionsList` throws instead of returning.
    var sessionsListError: (any Error)?
    /// How many `claudeSessionsList` calls the fake has served.
    var sessionsListCallCount = 0
    /// When set, `claudeSessionsList` parks here before answering.
    var sessionsListHold: RPCHoldGate?

    /// The response every single-session method returns.
    var sessionResponse = SupermuxClaudeSessionResultDTO(
        session: FakeSupermuxClaudeScript.makeSession()
    )
    /// When set, `claudeSessionCreate` throws instead of returning.
    var sessionCreateError: (any Error)?
    /// When set, `claudeSessionGet` throws instead of returning.
    var sessionGetError: (any Error)?
    /// How many `claudeSessionGet` calls the fake has served.
    var sessionGetCallCount = 0
    /// When set, `claudeSessionResume` throws instead of returning.
    var sessionResumeError: (any Error)?
    /// When set, `claudeSessionEnd` throws instead of returning.
    var sessionEndError: (any Error)?
    /// When set, `claudeSessionDelete` throws instead of returning.
    var sessionDeleteError: (any Error)?

    /// The response the next `claudeSend` call returns.
    var sendResponse = SupermuxClaudeSendResultDTO(queued: false)
    /// When set, `claudeSend` throws instead of returning.
    var sendError: (any Error)?
    /// When set, `claudeInterrupt` throws instead of returning.
    var interruptError: (any Error)?
    /// The response the next `claudeSetOption` call returns.
    var setOptionResponse = SupermuxClaudeSetOptionResultDTO(appliedValue: .string("opus"))
    /// When set, `claudeSetOption` throws instead of returning.
    var setOptionError: (any Error)?

    /// The response the next `claudeOptions` call returns.
    var optionsResponse = SupermuxClaudeOptionsDTO(
        models: [],
        supportedEffortLevels: [],
        supportsFastMode: false,
        slashCommands: [],
        launchers: []
    )
    /// When set, `claudeOptions` throws instead of returning.
    var optionsError: (any Error)?

    /// The newest history page returned when ``historyPages`` is exhausted.
    var historyPage = SupermuxClaudeHistoryPageDTO(messages: [], hasMore: false)
    /// Scripted newest-page responses, consumed in FIFO order.
    var historyPages: [SupermuxClaudeHistoryPageDTO] = []
    /// Scripted older-page (`before_seq`) responses, consumed in FIFO order.
    var olderHistoryPages: [SupermuxClaudeHistoryPageDTO] = []
    /// When set, `claudeHistory` throws instead of returning.
    var historyError: (any Error)?
    /// How many `claudeHistory` calls the fake has served.
    var historyCallCount = 0

    /// Scripted `claudeToolPayload` chunks, consumed in FIFO order.
    var toolPayloadChunks: [SupermuxClaudeToolPayloadChunkDTO] = []
    /// When set, `claudeToolPayload` throws instead of returning.
    var toolPayloadError: (any Error)?

    /// Every `claudeWatch` call, in order.
    var watchCalls: [(enable: Bool, clientID: String)] = []
    /// When set, `claudeWatch` throws instead of returning.
    var watchError: (any Error)?

    /// A minimal valid session snapshot for tests that only care about ids.
    static func makeSession(
        id: String = "session-1",
        state: SupermuxClaudeSessionState = .idle,
        version: UInt64 = 1,
        lastActivityAt: Double? = 100
    ) -> SupermuxClaudeSessionDTO {
        SupermuxClaudeSessionDTO(
            sessionID: id,
            title: "Session",
            cwd: "/repo",
            launcher: .claude,
            state: state,
            cost: SupermuxClaudeCostDTO(totalUSD: 0, turns: 0, durationMS: 0),
            lastActivityAt: lastActivityAt,
            version: version
        )
    }

    /// A minimal valid transcript message.
    static func makeMessage(
        id: String,
        seq: UInt64,
        text: String = "hello",
        role: SupermuxClaudeChatRole = .assistant
    ) -> SupermuxClaudeChatMessageDTO {
        SupermuxClaudeChatMessageDTO(
            id: id,
            seq: seq,
            role: role,
            timestamp: 1,
            kind: .prose,
            text: text
        )
    }
}

import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The `mobile.supermux.changes.*` half of ``FakeSupermuxMacClient`` — split
/// from the main file to respect the per-file length budget. Behavior is
/// byte-identical to the pre-split methods; recording goes through the main
/// file's `record`/`count…` seams (the recorded storage stays `private(set)`).
extension FakeSupermuxMacClient {
    func changesWatch(_ request: SupermuxChangesWatchRequest) async throws -> SupermuxChangesWatchResponse {
        record("changesWatch", method: request.wireMethod, params: request.wireParams)
        if let changesWatchError { throw changesWatchError }
        return SupermuxChangesWatchResponse(watching: request.enable, ttlSeconds: 120)
    }

    func changesStatus(_ request: SupermuxChangesStatusRequest) async throws -> SupermuxChangesStatusDTO {
        record("changesStatus", method: request.wireMethod, params: request.wireParams)
        if let changesStatusError { throw changesStatusError }
        countChangesStatusCall()
        return changesStatusResponse
    }

    func changesDiff(_ request: SupermuxChangesDiffRequest) async throws -> SupermuxDiffDTO {
        record("changesDiff", method: request.wireMethod, params: request.wireParams)
        if let changesDiffError { throw changesDiffError }
        return changesDiffResponse
    }

    func changesStage(_ request: SupermuxChangesStageRequest) async throws -> SupermuxChangesAckResponse {
        record("changesStage", method: request.wireMethod, params: request.wireParams)
        if let changesStageError { throw changesStageError }
        return SupermuxChangesAckResponse(ok: true)
    }

    func changesUnstage(_ request: SupermuxChangesUnstageRequest) async throws -> SupermuxChangesAckResponse {
        record("changesUnstage", method: request.wireMethod, params: request.wireParams)
        if let changesUnstageError { throw changesUnstageError }
        return SupermuxChangesAckResponse(ok: true)
    }

    func changesDiscard(_ request: SupermuxChangesDiscardRequest) async throws -> SupermuxChangesAckResponse {
        record("changesDiscard", method: request.wireMethod, params: request.wireParams)
        if let changesDiscardError { throw changesDiscardError }
        return SupermuxChangesAckResponse(ok: true)
    }

    func changesCommit(_ request: SupermuxChangesCommitRequest) async throws -> SupermuxChangesCommitResponse {
        record("changesCommit", method: request.wireMethod, params: request.wireParams)
        if let changesCommitError { throw changesCommitError }
        return changesCommitResponse
    }

    func changesGenerateCommitMessage(
        _ request: SupermuxChangesGenerateCommitMessageRequest
    ) async throws -> SupermuxChangesGeneratedMessageResponse {
        record("changesGenerateCommitMessage", method: request.wireMethod, params: request.wireParams)
        if let generateCommitMessageError { throw generateCommitMessageError }
        return generateCommitMessageResponse
    }

    func changesPush(_ request: SupermuxChangesPushRequest) async throws -> SupermuxChangesSyncResponse {
        record(
            "changesPush",
            method: request.wireMethod,
            params: request.wireParams,
            syncTimeoutNanoseconds: request.rpcTimeoutNanoseconds
        )
        if let changesPushError { throw changesPushError }
        return changesPushResponse
    }

    func changesPull(_ request: SupermuxChangesPullRequest) async throws -> SupermuxChangesSyncResponse {
        record(
            "changesPull",
            method: request.wireMethod,
            params: request.wireParams,
            syncTimeoutNanoseconds: request.rpcTimeoutNanoseconds
        )
        if let changesPullError { throw changesPullError }
        return changesPullResponse
    }

    func changesStash(_ request: SupermuxChangesStashRequest) async throws -> SupermuxChangesSyncResponse {
        record("changesStash", method: request.wireMethod, params: request.wireParams)
        if let changesStashError { throw changesStashError }
        return SupermuxChangesSyncResponse(ok: true, logLines: [])
    }

    func changesStashPop(_ request: SupermuxChangesStashPopRequest) async throws -> SupermuxChangesSyncResponse {
        record("changesStashPop", method: request.wireMethod, params: request.wireParams)
        if let changesStashPopError { throw changesStashPopError }
        return SupermuxChangesSyncResponse(ok: true, logLines: [])
    }

    func changesHistory(_ request: SupermuxChangesHistoryRequest) async throws -> SupermuxChangesHistoryResponse {
        record("changesHistory", method: request.wireMethod, params: request.wireParams)
        if let changesHistoryError { throw changesHistoryError }
        guard !changesHistoryResponses.isEmpty else {
            return SupermuxChangesHistoryResponse(commits: [])
        }
        return changesHistoryResponses.removeFirst()
    }
}

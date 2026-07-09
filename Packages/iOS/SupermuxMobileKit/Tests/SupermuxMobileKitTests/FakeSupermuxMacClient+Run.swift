import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The run / preset-launch / action half of ``FakeSupermuxMacClient`` —
/// split from the main file to respect the per-file length budget. Behavior
/// is byte-identical to the pre-split methods; recording goes through the
/// main file's `record`/`count…` seams.
extension FakeSupermuxMacClient {
    func runState(_ request: SupermuxRunStateRequest) async throws -> SupermuxRunStateResponse {
        record("runState", method: request.wireMethod, params: request.wireParams)
        if let runStateError { throw runStateError }
        countRunStateCall()
        return runStateResponse
    }

    func runStart(_ request: SupermuxRunStartRequest) async throws -> SupermuxRunWriteResponse {
        record("runStart", method: request.wireMethod, params: request.wireParams)
        if let runStartError { throw runStartError }
        return runStartResponse ?? SupermuxRunWriteResponse(
            run: SupermuxRunStateDTO(projectId: request.projectID, isRunning: true)
        )
    }

    func runStop(_ request: SupermuxRunStopRequest) async throws -> SupermuxRunWriteResponse {
        record("runStop", method: request.wireMethod, params: request.wireParams)
        if let runStopError { throw runStopError }
        return runStopResponse ?? SupermuxRunWriteResponse(
            run: SupermuxRunStateDTO(projectId: request.projectID, isRunning: false)
        )
    }

    func presetLaunch(_ request: SupermuxPresetLaunchRequest) async throws -> SupermuxPresetLaunchResponse {
        record("presetLaunch", method: request.wireMethod, params: request.wireParams)
        if let presetLaunchError { throw presetLaunchError }
        return presetLaunchResponse
    }

    func actionRun(_ request: SupermuxActionRunRequest) async throws -> SupermuxActionRunResponse {
        record("actionRun", method: request.wireMethod, params: request.wireParams)
        if let actionRunError { throw actionRunError }
        return actionRunResponse
    }
}

import CMUXMobileCore
import CmuxIrxTransport
import Foundation
import SupermuxMobileCore

/// The host side of `mobile.supermux.route.candidates`: this Mac's iroh
/// endpoint id and its servable direct addresses
/// (``SupermuxRouteCandidates/servable(_:)``), for another of the user's
/// devices to dial it directly.
///
/// Answered before the main-actor RPC dispatch (the `route-candidates-off-main`
/// fence in `MobileHostService.acceptTransport`): it is a small reply that
/// must not wait behind replays captured on the main thread. Only an
/// Iroh-admitted session (a Mac peer or a phone of the same account) gets
/// it; the addresses go nowhere else, never to the backend.
enum SupermuxRouteCandidatesHost {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var supervisor: IrxEndpointSupervisor?
        private var debugServed: SupermuxRouteCandidatesDTO?
        private var served = 0

        var cachedSupervisor: IrxEndpointSupervisor? { lock.withLock { supervisor } }
        func cache(_ value: IrxEndpointSupervisor?) { lock.withLock { supervisor = value } }
        var debugAnswer: SupermuxRouteCandidatesDTO? {
            get { lock.withLock { debugServed } }
            set { lock.withLock { debugServed = newValue } }
        }
        func countServed() { lock.withLock { served += 1 } }
        var servedCount: Int { lock.withLock { served } }
    }

    private static let state = State()

    /// The answer for an Iroh-admitted session, before the main-actor
    /// dispatch; nil for every other method.
    nonisolated static func answer(
        _ request: MobileHostRPCRequest,
        authorization: MobileHostConnectionAuthorizationContext
    ) async -> MobileHostRPCResult? {
        guard request.method == SupermuxMobileMethod.routeCandidates.rawValue else { return nil }
        guard case .irohAdmission = authorization else {
            return .failure(MobileHostRPCError(code: "forbidden", message: "Direct addresses are only shared over Iroh"))
        }
        return .ok(await payload())
    }

    /// The same answer from the `mobile.supermux.*` router (reached only by
    /// callers the early answer did not take: refused unless Iroh-admitted).
    nonisolated static func callResult(executionContext: MobileHostRPCExecutionContext?) async -> TerminalController.V2CallResult {
        guard let executionContext, case .irohAdmission = executionContext.authorization else {
            return .err(code: "forbidden", message: "Direct addresses are only shared over Iroh", data: nil)
        }
        return .ok(await payload())
    }

    private nonisolated static func payload() async -> [String: Any] {
        state.countServed()
        let answer = await currentAnswer()
        return [
            "endpoint_id": answer.endpointID ?? NSNull(),
            "addresses": answer.addresses,
        ]
    }

    private nonisolated static func currentAnswer() async -> SupermuxRouteCandidatesDTO {
        #if DEBUG
        if let pinned = state.debugAnswer {
            return SupermuxRouteCandidatesDTO(
                endpointID: pinned.endpointID, addresses: SupermuxRouteCandidates.servable(pinned.addresses))
        }
        #endif
        // The runtime's supervisor is read on the main actor only when none
        // is cached or the cached one answers nothing (closed, replaced).
        if let cached = state.cachedSupervisor, let answer = await answer(from: cached) { return answer }
        let current = await MainActor.run { MobileHostIrxRuntime.shared.endpointSupervisor }
        state.cache(current)
        guard let current else { return SupermuxRouteCandidatesDTO(endpointID: nil, addresses: []) }
        if let answer = await answer(from: current) { return answer }
        return SupermuxRouteCandidatesDTO(endpointID: await current.identity().endpointIDHex, addresses: [])
    }

    private nonisolated static func answer(from supervisor: IrxEndpointSupervisor) async -> SupermuxRouteCandidatesDTO? {
        let addresses = SupermuxRouteCandidates.servable(await supervisor.localDirectAddresses())
        guard !addresses.isEmpty else { return nil }
        return SupermuxRouteCandidatesDTO(endpointID: await supervisor.identity().endpointIDHex, addresses: addresses)
    }

    #if DEBUG
    /// Pins the answer (DEBUG driver `supermux.devices.route.candidates_serve`);
    /// nil serves the real endpoint again. The servable filter still applies.
    nonisolated static func pinAnswer(_ answer: SupermuxRouteCandidatesDTO?) {
        state.debugAnswer = answer
    }

    /// Answers served since launch (DEBUG driver).
    nonisolated static var servedCount: Int { state.servedCount }
    #endif
}

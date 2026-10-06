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
///
/// Two answers are refusals the asker reads by their code
/// (``SupermuxRouteCandidateFetchSchedule/Answer``):
/// - `not_ready` while the endpoint has no direct address yet (iroh fills
///   them after its first network report, 1–3 s after binding). The asker
///   keeps what it had and asks again in a minute; an empty list would have
///   wiped it on an older asker.
/// - `direct_off` when this host is forced to relay: the asker forgets this
///   Mac's addresses, so no device dials it directly.
enum SupermuxRouteCandidatesHost {
    /// What this host says.
    private enum Reply {
        case answer(SupermuxRouteCandidatesDTO)
        case refusal(code: String, message: String)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var supervisor: IrxEndpointSupervisor?
        private var debugServed: Reply?
        private var served = 0

        var cachedSupervisor: IrxEndpointSupervisor? { lock.withLock { supervisor } }
        func cache(_ value: IrxEndpointSupervisor?) { lock.withLock { supervisor = value } }
        var debugReply: Reply? {
            get { lock.withLock { debugServed } }
            set { lock.withLock { debugServed = newValue } }
        }
        func countServed() { lock.withLock { served += 1 } }
        var servedCount: Int { lock.withLock { served } }
    }

    private static let state = State()

    /// Whether ``answer(_:authorization:)`` takes `request`: checked before
    /// awaiting it, since every request of every connection passes here.
    nonisolated static func answers(_ request: MobileHostRPCRequest) -> Bool {
        request.method == SupermuxMobileMethod.routeCandidates.rawValue
    }

    /// The answer for an Iroh-admitted session, before the main-actor
    /// dispatch; nil for every other method.
    nonisolated static func answer(
        _ request: MobileHostRPCRequest,
        authorization: MobileHostConnectionAuthorizationContext
    ) async -> MobileHostRPCResult? {
        guard answers(request) else { return nil }
        guard case .irohAdmission = authorization else {
            return .failure(MobileHostRPCError(code: "forbidden", message: "Direct addresses are only shared over Iroh"))
        }
        switch await reply() {
        case .answer(let answer): return .ok(payload(answer))
        case .refusal(let code, let message): return .failure(MobileHostRPCError(code: code, message: message))
        }
    }

    /// The same answer from the `mobile.supermux.*` router (reached only by
    /// callers the early answer did not take: refused unless Iroh-admitted).
    nonisolated static func callResult(executionContext: MobileHostRPCExecutionContext?) async -> TerminalController.V2CallResult {
        guard let executionContext, case .irohAdmission = executionContext.authorization else {
            return .err(code: "forbidden", message: "Direct addresses are only shared over Iroh", data: nil)
        }
        switch await reply() {
        case .answer(let answer): return .ok(payload(answer))
        case .refusal(let code, let message): return .err(code: code, message: message, data: nil)
        }
    }

    private nonisolated static func payload(_ answer: SupermuxRouteCandidatesDTO) -> [String: Any] {
        ["endpoint_id": answer.endpointID ?? NSNull(), "addresses": answer.addresses]
    }

    private nonisolated static func reply() async -> Reply {
        state.countServed()
        #if DEBUG
        if let pinned = state.debugReply {
            guard case .answer(let answer) = pinned else { return pinned }
            return .answer(SupermuxRouteCandidatesDTO(
                endpointID: answer.endpointID, addresses: SupermuxRouteCandidates.servable(answer.addresses)))
        }
        #endif
        guard MobileHostIrxRuntime.pathMode != .relayOnly else {
            return .refusal(code: SupermuxRouteCandidates.directOffErrorCode, message: "This Mac only uses the relay")
        }
        // The runtime's supervisor is read on the main actor only when none
        // is cached or the cached one answers nothing (closed, replaced).
        if let cached = state.cachedSupervisor, let answer = await answer(from: cached) { return .answer(answer) }
        let current = await MainActor.run { MobileHostIrxRuntime.shared.endpointSupervisor }
        state.cache(current)
        // No endpoint at all (Iroh is off): nothing will come; an empty list.
        guard let current else { return .answer(SupermuxRouteCandidatesDTO(endpointID: nil, addresses: [])) }
        if let answer = await answer(from: current) { return .answer(answer) }
        return .refusal(code: SupermuxRouteCandidates.notReadyErrorCode, message: "This Mac has no direct address yet")
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
        state.debugReply = answer.map { .answer($0) }
    }

    /// Pins a refusal (`not_ready` or `direct_off`) instead (DEBUG driver).
    nonisolated static func pinRefusal(code: String) {
        state.debugReply = .refusal(code: code, message: "pinned by the DEBUG driver")
    }

    /// Answers served since launch (DEBUG driver).
    nonisolated static var servedCount: Int { state.servedCount }
    #endif
}

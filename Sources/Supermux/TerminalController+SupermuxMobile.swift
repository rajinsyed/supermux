import Foundation
import SupermuxMobileCore

/// The `mobile.supermux.*` RPC router: the single dispatch case in
/// `mobileHostHandleRPC` (the `mobile-supermux-dispatch` fence) routes the
/// whole namespace here, mirroring `TerminalController+MobileChat.swift`, so
/// the upstream god-file grows by one fenced case regardless of how many
/// supermux methods exist.
///
/// Ticket scoping for these methods is enforced upstream of dispatch by
/// ``SupermuxMobileAuthorization`` (the `mobile-supermux-authz` fence in
/// `MobileHostService`); handlers here can assume an authorized caller.
extension TerminalController {
    /// Routes one `mobile.supermux.*` method to its handler.
    ///
    /// - Parameters:
    ///   - method: The wire method string.
    ///   - params: The request params.
    /// - Returns: The handler's result, or `method_not_found` for methods this
    ///   host does not serve (yet) — the phone gates each screen on the
    ///   advertised ``SupermuxMobileCapabilities`` instead of probing.
    func v2MobileSupermuxDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        switch SupermuxMobileMethod(rawValue: method) {
        case .projectsList:
            return await v2SupermuxProjectsList(params: params)
        case .projectIcon:
            return await v2SupermuxProjectIcon(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": method
            ])
        }
    }
}

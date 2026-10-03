import Foundation
import SupermuxMobileCore

/// `mobile.supermux.ports.list`: this Mac's ports for another of the user's
/// Macs to forward (``SupermuxHostPorts``). Only an admitted Mac peer may
/// list them; phones never forward ports (their "On iPhone" browser lists
/// loopback listeners over its own tunnel lane).
extension TerminalController {
    func v2SupermuxPortsList(
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext?
    ) async -> V2CallResult {
        guard SupermuxMobilePeerPolicy.isAdmittedMacPeer(executionContext) else {
            return .err(code: "forbidden", message: "Ports are listed only for another of your Macs", data: nil)
        }
        let list = await SupermuxHostPorts.list(includeOther: params["include_other"] as? Bool == true)
        guard let data = try? JSONEncoder().encode(list),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .err(code: "internal_error", message: "Ports could not be encoded", data: nil)
        }
        return .ok(object)
    }
}

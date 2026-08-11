import Foundation
import SupermuxKit

/// `mobile.supermux.phone_push.*` handlers for the personal direct-APNs lane.
extension TerminalController {
    /// Registers or removes the paired iPhone's APNs token on this Mac.
    func v2SupermuxPhonePushRegister(params: [String: Any]) async -> V2CallResult {
        guard let deviceToken = v2String(params, "device_token"),
              let bundleID = v2String(params, "bundle_id"),
              let environmentRaw = v2String(params, "environment"),
              let environment = SupermuxPhonePushService.Environment(rawValue: environmentRaw),
              let enabled = v2Bool(params, "enabled") else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid phone push registration parameters",
                data: nil
            )
        }
        do {
            let registered = try await SupermuxComposition.phonePushService.register(
                deviceID: v2String(params, "device_id"),
                deviceToken: deviceToken,
                previousDeviceToken: v2String(params, "previous_device_token"),
                bundleID: bundleID,
                environment: environment,
                enabled: enabled
            )
            return .ok(["registered": registered])
        } catch {
            return .err(
                code: "invalid_params",
                message: "Invalid phone push registration",
                data: nil
            )
        }
    }
}

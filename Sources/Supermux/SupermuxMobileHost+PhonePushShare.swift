import CmuxIrohTransport
import Foundation
import OSLog
import SupermuxKit

private let phonePushShareLog = Logger(subsystem: "dev.supermux", category: "phone-push-share")

/// Who may hand this Mac push credentials: only another of the user's Macs,
/// admitted over Iroh as a Mac (`CmxIrohAdmittedPeer.platform == .mac`).
/// A phone (`.ios`), a peer admitted without a platform, the Stack-bearer
/// path and in-process callers without a connection are all refused.
enum SupermuxMobilePeerPolicy {
    /// Whether the request arrived from an Iroh-admitted Mac peer.
    static func isAdmittedMacPeer(_ context: MobileHostRPCExecutionContext?) -> Bool {
        guard let context, case .irohAdmission(let peer) = context.authorization else { return false }
        return peer.platform == .mac
    }
}

/// `mobile.supermux.phone_push.status` and `.share`: provisioning the direct
/// APNs lane between the user's Macs, so the Mac that runs an agent can push
/// even when the phone never focused it (see ``SupermuxPhonePushShareCoordinator``).
extension TerminalController {
    /// This Mac's direct-APNs state for another Mac. No secrets: the key is
    /// described only by its identifiers and a short fingerprint.
    func v2SupermuxPhonePushStatus() async -> V2CallResult {
        let status = await SupermuxComposition.phonePushService.status(
            shareEnabled: SupermuxComposition.devicesSettings.sharePush
        )
        guard let data = try? JSONEncoder().encode(status),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .err(code: "internal_error", message: "Phone push status could not be encoded", data: nil)
        }
        return .ok(object)
    }

    /// Installs shared credentials where none exist and merges registrations.
    /// Refused unless the caller is an admitted Mac peer and sharing is on here.
    func v2SupermuxPhonePushShare(
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext?
    ) async -> V2CallResult {
        guard SupermuxMobilePeerPolicy.isAdmittedMacPeer(executionContext) else {
            phonePushShareLog.notice("refused phone_push.share from a non-Mac caller")
            return .err(
                code: "forbidden",
                message: "Push credentials are accepted only from another of your Macs",
                data: nil
            )
        }
        guard SupermuxComposition.devicesSettings.sharePush else {
            return .err(code: "share_disabled", message: "Push sharing is turned off on this Mac", data: nil)
        }
        let request: SupermuxPhonePushShareRequest
        do {
            request = try SupermuxPhonePushShareRequest(wireParams: params)
        } catch {
            return .err(code: "invalid_params", message: "Malformed phone push share", data: nil)
        }
        do {
            let result = try await SupermuxComposition.phonePushService.acceptShare(request)
            phonePushShareLog.info(
                "phone_push.share credentials=\(result.credentials.rawValue, privacy: .public) added=\(result.registrationsAdded) total=\(result.registrationCount)"
            )
            return .ok(result.wireResult)
        } catch {
            phonePushShareLog.error("phone_push.share could not write the push state")
            return .err(code: "write_failed", message: "Push state could not be saved on this Mac", data: nil)
        }
    }
}

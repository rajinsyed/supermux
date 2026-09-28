#if DEBUG
import CMUXMobileCore
import CmuxCloud
import CmuxIrohTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// DEBUG-only `supermux.devices.*` hooks for the notification and phone-push
/// E2E (`tests/supermux/loopback_notifications_e2e.py`), routed from
/// ``SupermuxDevicesSocketCommands``:
///
/// - `push_decisions {clear?}`: the phone-forwarding decision log plus the
///   local unread count and the phone-facing badge.
/// - `notification_records {}`: local records with origin, read state,
///   correlation key and project (what `notification.list` leaves out).
/// - `notification_overrides {presence?, window_key?}`: `"present"`/`"away"`
///   and `"key"`/`"not_key"` overrides for the focused-pane policy; `"live"`
///   clears one.
/// - `phone_push_debug {}`: the direct lane's directory, its status, the share
///   coordinator's attempts and pending notification retries.
/// - `phone_push_probe {caller, method, params?}`: runs `phone_push.status` /
///   `phone_push.share` as a synthetic `mac`, `ios`, `stack_bearer` or `none`
///   caller, to prove the share gate refuses every non-Mac path.
/// - `phone_push_share_now {machine}`: runs the share coordinator for one device.
@MainActor
enum SupermuxDeviceNotificationSocketCommands {
    private static let methods: Set<String> = [
        "push_decisions", "notification_records", "notification_overrides",
        "phone_push_debug", "phone_push_probe", "phone_push_share_now",
    ]

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Whether `name` (the part after `supermux.devices.`) is one of these hooks.
    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        methods.contains(String(name))
    }

    static func handle(_ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "push_decisions":
            if params["clear"] as? Bool == true { SupermuxPhonePushDecisionLog.shared.clear() }
            return badgeCounts().merging(["decisions": SupermuxPhonePushDecisionLog.shared.payload]) { $1 }
        case "notification_records":
            return badgeCounts().merging(["records": records()]) { $1 }
        case "notification_overrides":
            return try overrides(params)
        case "phone_push_debug":
            return await phonePushDebug()
        case "phone_push_probe":
            return try await probe(params)
        case "phone_push_share_now":
            guard let raw = params["machine"] as? String, SurfaceMachineID(rawValue: raw).isDevice else {
                throw HookError(message: "machine must be a device id")
            }
            return ["result": await SupermuxComposition.phonePushShareCoordinator.share(with: SurfaceMachineID(rawValue: raw))]
        default:
            throw HookError(message: "unknown hook \(name)")
        }
    }

    // MARK: - Hooks

    private static func badgeCounts() -> [String: Any] {
        guard let store = AppDelegate.shared?.notificationStore else { return [:] }
        return [
            "unread_count": store.unreadNotificationCount,
            "phone_badge_count": store.supermuxPhoneBadgeCount,
        ]
    }

    private static func records() -> [[String: Any]] {
        guard let store = AppDelegate.shared?.notificationStore else { return [] }
        return store.notifications.map { notification in
            var record: [String: Any] = [
                "id": notification.id.uuidString,
                "workspace_id": notification.tabId.uuidString,
                "surface_id": notification.surfaceId.map { $0.uuidString as Any } ?? NSNull(),
                "title": notification.title,
                "subtitle": notification.subtitle,
                "is_read": notification.isRead,
                "origin": notification.origin.wireValue,
                "correlation_key": notification.correlationKey.map { $0 as Any } ?? NSNull(),
                "project": NSNull(),
            ]
            if let project = notification.project {
                record["project"] = ["id": project.id, "name": project.name]
            }
            return record
        }
    }

    private static func overrides(_ params: [String: Any]) throws -> [String: Any] {
        if let presence = params["presence"] as? String {
            switch presence {
            case "present": SupermuxMacPresence.debugOverride = true
            case "away": SupermuxMacPresence.debugOverride = false
            case "live": SupermuxMacPresence.debugOverride = nil
            default: throw HookError(message: "presence must be present, away or live")
            }
        }
        if let windowKey = params["window_key"] as? String {
            switch windowKey {
            case "key": SupermuxFocusedPaneNotificationPolicy.debugTargetWindowIsKey = true
            case "not_key": SupermuxFocusedPaneNotificationPolicy.debugTargetWindowIsKey = false
            case "live": SupermuxFocusedPaneNotificationPolicy.debugTargetWindowIsKey = nil
            default: throw HookError(message: "window_key must be key, not_key or live")
            }
        }
        return [
            "presence_source": SupermuxMacPresence.source(),
            "user_is_present": SupermuxMacPresence.isUserPresent(),
            "window_key_override": SupermuxFocusedPaneNotificationPolicy.debugTargetWindowIsKey.map { $0 as Any } ?? NSNull(),
        ]
    }

    private static func phonePushDebug() async -> [String: Any] {
        let service = SupermuxComposition.phonePushService
        let status = await service.status(shareEnabled: SupermuxComposition.devicesSettings.sharePush)
        let encoded = (try? JSONEncoder().encode(status)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return [
            "base_directory": service.baseDirectory.path,
            "status": encoded ?? NSNull(),
            "share_attempts": SupermuxComposition.phonePushShareCoordinator.attempts.map { attempt in
                [
                    "machine": attempt.machine,
                    "result": attempt.result,
                    "sent_credentials": attempt.sentCredentials,
                    "sent_registrations": attempt.sentRegistrations,
                    "at": attempt.at.timeIntervalSince1970,
                ] as [String: Any]
            },
            "retry_pending": SupermuxComposition.deviceNotificationRetry.pendingMachineIDs,
        ]
    }

    private static func probe(_ params: [String: Any]) async throws -> [String: Any] {
        let caller = params["caller"] as? String ?? "none"
        let method: SupermuxMobileMethod
        switch params["method"] as? String {
        case "status": method = .phonePushStatus
        case "share": method = .phonePushShare
        default: throw HookError(message: "method must be status or share")
        }
        let result = await TerminalController.shared.v2MobileSupermuxDispatch(
            method: method.rawValue,
            params: params["params"] as? [String: Any] ?? [:],
            executionContext: try executionContext(caller: caller)
        )
        switch result {
        case .ok(let payload):
            return ["ok": true, "result": payload]
        case .err(let code, let message, _):
            return ["ok": false, "error": ["code": code, "message": message]]
        }
    }

    private static func executionContext(caller: String) throws -> MobileHostRPCExecutionContext? {
        switch caller {
        case "none":
            return nil
        case "stack_bearer":
            return MobileHostRPCExecutionContext(connectionID: UUID(), authorization: .stackBearer, artifactTransfers: nil)
        case "mac", "ios":
            let peer = CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
                bindingID: "supermux-debug-probe",
                deviceID: UUID().uuidString.lowercased(),
                tag: MobileHostIdentity.instanceTag(),
                platform: caller == "mac" ? .mac : .ios,
                endpointID: try CmxIrohPeerIdentity(endpointID: String(repeating: "ab", count: 32)),
                identityGeneration: 1
            ))
            return MobileHostRPCExecutionContext(
                connectionID: UUID(),
                authorization: .irohAdmission(peer),
                artifactTransfers: nil
            )
        default:
            throw HookError(message: "caller must be mac, ios, stack_bearer or none")
        }
    }
}
#endif

#if DEBUG
import AppKit
import Bonsplit
import CMUXMobileCore
import CmuxCloud
import CmuxIrohTransport
import CmuxSettings
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
/// - `notification_overrides {presence?, window_key?, suppress_when_app_focused?}`:
///   `"present"`/`"away"` and `"key"`/`"not_key"` overrides for the
///   focused-pane policy (`"live"` clears one), and upstream's
///   `notifications.suppressWhenAppFocused` setting (`true`/`false`, `"live"`
///   removes the stored value). Reports each current value.
/// - `notification_mark_unread {id}`: Mark as Unread on one record, through the
///   same user-action path as the notification row's menu item.
/// - `notification_indicators {surface_id}`: what a pane shows for its
///   notifications: unread record, the focused-read indicator, the pane ring,
///   its tab's badge and the workspace's unread count.
/// - `notification_click {surface_id}`: a left click in the pane's terminal,
///   delivered to its view's `mouseDown`/`mouseUp` (the real pointer path),
///   then that pane's `notification_indicators`.
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
        "notification_mark_unread", "notification_indicators", "notification_click",
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
        case "notification_mark_unread":
            return try markUnread(params)
        case "notification_indicators":
            return try indicators(params)
        case "notification_click":
            return try click(params)
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
        let suppressKey = NotificationsCatalogSection().suppressWhenAppFocused.userDefaultsKey
        switch params["suppress_when_app_focused"] {
        case nil: break
        case let value as Bool: UserDefaults.standard.set(value, forKey: suppressKey)
        case let value as String where value == "live": UserDefaults.standard.removeObject(forKey: suppressKey)
        default: throw HookError(message: "suppress_when_app_focused must be true, false or live")
        }
        return [
            "presence_source": SupermuxMacPresence.source(),
            "user_is_present": SupermuxMacPresence.isUserPresent(),
            "window_key_override": SupermuxFocusedPaneNotificationPolicy.debugTargetWindowIsKey.map { $0 as Any } ?? NSNull(),
            "suppress_when_app_focused": TerminalNotificationStore.isSuppressWhenAppFocusedEnabled(),
            "suppress_when_app_focused_stored": UserDefaults.standard.object(forKey: suppressKey) ?? NSNull(),
        ]
    }

    private static func markUnread(_ params: [String: Any]) throws -> [String: Any] {
        guard let store = AppDelegate.shared?.notificationStore,
              let id = (params["id"] as? String).flatMap(UUID.init(uuidString:)),
              let notification = store.notifications.first(where: { $0.id == id }) else {
            throw HookError(message: "id must name a notification record")
        }
        if notification.isRead {
            store.toggleReadFromUserAction(notification)
        }
        let isRead = store.notifications.first { $0.id == id }?.isRead ?? false
        return ["id": id.uuidString, "is_read": isRead]
    }

    /// The pane `surface_id` names and the workspace that owns it.
    private static func pane(_ params: [String: Any]) throws -> (workspace: Workspace, surfaceID: UUID) {
        guard let surfaceID = (params["surface_id"] as? String).flatMap(UUID.init(uuidString:)),
              let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceID)?.workspace else {
            throw HookError(message: "surface_id must name an open pane")
        }
        return (workspace, surfaceID)
    }

    private static func indicators(_ params: [String: Any]) throws -> [String: Any] {
        guard let store = AppDelegate.shared?.notificationStore else { throw HookError(message: "no notification store") }
        let (workspace, surfaceID) = try pane(params)
        let tab = workspace.surfaceIdFromPanelId(surfaceID).flatMap { workspace.bonsplitController.tab($0) }
        let ring = workspace.terminalPanel(for: surfaceID)?.hostedView.debugNotificationRingState()
        return [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceID.uuidString,
            "is_app_focused": AppFocusState.isAppFocused(),
            "focused_surface_id": workspace.owningTabManager?.focusedSurfaceId(for: workspace.id)
                .map { $0.uuidString as Any } ?? NSNull(),
            "has_unread_notification": store.hasUnreadNotification(forTabId: workspace.id, surfaceId: surfaceID),
            "has_visible_indicator": store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: surfaceID),
            "focused_read_indicator_surface_id": store.focusedReadIndicatorSurfaceId(forTabId: workspace.id)
                .map { $0.uuidString as Any } ?? NSNull(),
            "workspace_unread_count": store.unreadCount(forTabId: workspace.id),
            "tab_shows_notification_badge": tab.map { $0.showsNotificationBadge as Any } ?? NSNull(),
            "ring_visible": ring.map { (!$0.isHidden && $0.opacity > 0) as Any } ?? NSNull(),
        ]
    }

    private static func click(_ params: [String: Any]) throws -> [String: Any] {
        let (workspace, surfaceID) = try pane(params)
        guard let view = workspace.terminalPanel(for: surfaceID)?.hostedView.surfaceView else {
            throw HookError(message: "surface_id is not a terminal")
        }
        guard let window = view.window else { throw HookError(message: "the terminal is not in a window") }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: center,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { throw HookError(message: "could not make a mouse event") }
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
        return try indicators(params)
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
            "retries_fired": SupermuxComposition.deviceNotificationRetry.firedCount,
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

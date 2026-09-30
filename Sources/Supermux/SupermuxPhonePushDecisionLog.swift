#if DEBUG
import Foundation

/// DEBUG-only record of every phone-forwarding decision, so an E2E run can
/// prove a viewer Mac skipped the phone for mirrored (`.deviceMac`) records
/// (`supermux.devices.push_decisions`). In memory, bounded, never persisted.
@MainActor
final class SupermuxPhonePushDecisionLog {
    static let shared = SupermuxPhonePushDecisionLog()

    /// One notification's decisions on both phone lanes.
    struct Entry {
        let notificationID: UUID
        let workspaceID: UUID
        let surfaceID: UUID?
        let title: String
        let originKind: String
        let upstreamRelayAttempted: Bool
        let direct: SupermuxPhoneForwardGate.DirectVerdict
        let badgeCount: Int
        let recordedAt: Date
    }

    private static let capacity = 200
    private(set) var entries: [Entry] = []

    func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Socket payload, oldest first.
    var payload: [[String: Any]] {
        entries.map { entry in
            [
                "notification_id": entry.notificationID.uuidString,
                "workspace_id": entry.workspaceID.uuidString,
                "surface_id": entry.surfaceID.map { $0.uuidString as Any } ?? NSNull(),
                "title": entry.title,
                "origin": entry.originKind,
                "upstream_relay_attempted": entry.upstreamRelayAttempted,
                "direct": entry.direct.rawValue,
                "badge_count": entry.badgeCount,
                "recorded_at": entry.recordedAt.timeIntervalSince1970,
            ]
        }
    }
}
#endif

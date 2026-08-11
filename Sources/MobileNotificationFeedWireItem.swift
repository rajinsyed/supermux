import Foundation
// SUPERMUX:begin notification-feed-project-wire
import SupermuxMobileCore
// SUPERMUX:end notification-feed-project-wire

nonisolated struct MobileNotificationFeedWireItem: Sendable {
    let id: String
    let workspaceID: String
    let surfaceID: String?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Double
    let isRead: Bool
    let retargetsToLiveSurfaceOwner: Bool
    let workspaceTitle: String?
    let surfaceTitle: String?
    // SUPERMUX:begin notification-feed-project-wire
    /// The owning project snapshot, so the phone's feed can render the same
    /// avatar, name, and accent the Mac shows. Optional and additive: an
    /// upstream cmux Mac sends nothing here and the phone renders upstream's
    /// project-less row.
    let project: SupermuxNotificationProject?
    // SUPERMUX:end notification-feed-project-wire

    var foundationPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "workspace_id": workspaceID,
            "title": title,
            "subtitle": subtitle,
            "body": body,
            "created_at": createdAt,
            "is_read": isRead,
            "retargets_to_live_surface_owner": retargetsToLiveSurfaceOwner,
        ]
        if let surfaceID {
            payload["surface_id"] = surfaceID
        }
        if let workspaceTitle {
            payload["workspace_title"] = workspaceTitle
        }
        if let surfaceTitle {
            payload["surface_title"] = surfaceTitle
        }
        // SUPERMUX:begin notification-feed-project-wire
        // Encoded as a nested object matching SupermuxNotificationProject's
        // own snake_case Codable keys, so the phone decodes it with the shared
        // type rather than a hand-rolled parallel parser.
        if let project {
            payload["supermux_project"] = [
                "id": project.id,
                "name": project.name,
                "color_hex": project.colorHex as Any?,
                "icon_symbol": project.iconSymbol as Any?,
                "icon_etag": project.iconETag as Any?,
            ].compactMapValues { $0 }
        }
        // SUPERMUX:end notification-feed-project-wire
        return payload
    }
}

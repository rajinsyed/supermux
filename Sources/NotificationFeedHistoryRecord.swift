import Foundation
// SUPERMUX:begin notification-project-identity
import SupermuxMobileCore
// SUPERMUX:end notification-project-identity

/// One durable cmux notification in the cross-device chronological feed.
struct NotificationFeedHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    static let historyTitleByteLimit = 512
    static let historySubtitleByteLimit = 512
    static let historyBodyByteLimit = 2_048
    // SUPERMUX:begin notification-project-identity
    /// Cap on the persisted project name, matching the other metadata limits so
    /// one pathological project name cannot inflate every history record.
    static let historyProjectNameByteLimit = 256
    // SUPERMUX:end notification-project-identity

    let id: UUID
    var tabId: UUID
    var surfaceId: UUID?
    var panelId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    // SUPERMUX:begin notification-project-identity
    /// The owning project snapshot, persisted so a restored feed still renders
    /// project avatars. Optional in the Codable shape (see the explicit
    /// `decodeIfPresent` below): records written before this field existed must
    /// keep decoding, or the whole durable history is lost on upgrade.
    var project: SupermuxNotificationProject?
    // SUPERMUX:end notification-project-identity

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        retargetsToLiveSurfaceOwner: Bool,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        // SUPERMUX:begin notification-project-identity
        project: SupermuxNotificationProject? = nil
        // SUPERMUX:end notification-project-identity
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        // SUPERMUX:begin notification-project-identity
        self.project = project
        // SUPERMUX:end notification-project-identity
    }

    init(notification: TerminalNotification) {
        id = notification.id
        tabId = notification.tabId
        surfaceId = notification.surfaceId
        panelId = notification.panelId
        retargetsToLiveSurfaceOwner = notification.retargetsToLiveSurfaceOwner
        title = notification.title
        subtitle = notification.subtitle
        body = notification.body
        createdAt = notification.createdAt
        isRead = notification.isRead
        // SUPERMUX:begin notification-project-identity
        project = notification.project
        // SUPERMUX:end notification-project-identity
    }

    // SUPERMUX:begin notification-project-identity
    /// Explicit coding keys + a tolerant decoder. Synthesized `Codable` on an
    /// `Optional` property already decodes a missing key as `nil`, but only
    /// while the property stays optional — spelling both out here makes the
    /// backward-compatibility contract of the persisted feed explicit rather
    /// than an accident of synthesis, and keeps a future non-optional refactor
    /// from silently discarding every pre-existing record.
    private enum CodingKeys: String, CodingKey {
        case id, tabId, surfaceId, panelId, retargetsToLiveSurfaceOwner
        case title, subtitle, body, createdAt, isRead
        case project
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabId = try container.decode(UUID.self, forKey: .tabId)
        surfaceId = try container.decodeIfPresent(UUID.self, forKey: .surfaceId)
        panelId = try container.decodeIfPresent(UUID.self, forKey: .panelId)
        retargetsToLiveSurfaceOwner = try container.decode(
            Bool.self, forKey: .retargetsToLiveSurfaceOwner
        )
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isRead = try container.decode(Bool.self, forKey: .isRead)
        project = try container.decodeIfPresent(
            SupermuxNotificationProject.self, forKey: .project
        )
    }
    // SUPERMUX:end notification-project-identity

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }

    func boundedForHistory() -> NotificationFeedHistoryRecord {
        NotificationFeedHistoryRecord(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            title: Self.string(title, limitedToUTF8Bytes: Self.historyTitleByteLimit),
            subtitle: Self.string(subtitle, limitedToUTF8Bytes: Self.historySubtitleByteLimit),
            body: Self.string(body, limitedToUTF8Bytes: Self.historyBodyByteLimit),
            createdAt: createdAt,
            isRead: isRead,
            // SUPERMUX:begin notification-project-identity
            project: project.map(Self.boundedProject)
            // SUPERMUX:end notification-project-identity
        )
    }

    // SUPERMUX:begin notification-project-identity
    /// Bounds the persisted project name the same way every other stored
    /// string is bounded. Ids, hexes, and symbol names are already
    /// fixed-length by construction, so only the name needs clamping.
    private static func boundedProject(
        _ project: SupermuxNotificationProject
    ) -> SupermuxNotificationProject {
        var bounded = project
        bounded.name = string(project.name, limitedToUTF8Bytes: historyProjectNameByteLimit)
        return bounded
    }
    // SUPERMUX:end notification-project-identity

    private static func string(_ value: String, limitedToUTF8Bytes maxBytes: Int) -> String {
        guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
        var byteCount = 0
        var endIndex = value.startIndex
        while endIndex < value.endIndex {
            let nextIndex = value.index(after: endIndex)
            let characterByteCount = value[endIndex..<nextIndex].utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            byteCount += characterByteCount
            endIndex = nextIndex
        }
        return String(value[..<endIndex])
    }
}

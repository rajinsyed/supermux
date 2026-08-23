import Foundation
// SUPERMUX:begin notification-feed-project-wire
import SupermuxMobileCore
// SUPERMUX:end notification-feed-project-wire

struct MobileNotificationFeedListBoundedItem: Decodable {
    let item: MobileNotificationFeedListItem?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case title
        case subtitle
        case body
        case createdAt = "created_at"
        case isRead = "is_read"
        case retargetsToLiveSurfaceOwner = "retargets_to_live_surface_owner"
        case workspaceTitle = "workspace_title"
        case surfaceTitle = "surface_title"
        // SUPERMUX:begin notification-feed-project-wire
        // THE production decode path. A field added only to
        // MobileNotificationFeedListItem decodes as nil here while its unit
        // tests pass — this duplicate key set is the one that actually runs.
        case project = "supermux_project"
        // SUPERMUX:end notification-feed-project-wire
    }

    init(from decoder: any Decoder) throws {
        let options = try mobileNotificationFeedListBoundedDecodeOptions(from: decoder)
        let limits = options.stringLimits
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
        guard let id = try mobileNotificationFeedListIdentityString(
            from: container,
            forKey: .id,
            limitedToUTF8Bytes: limits.identifierByteLimit
        ),
            let workspaceID = try mobileNotificationFeedListIdentityString(
                from: container,
                forKey: .workspaceID,
                limitedToUTF8Bytes: limits.identifierByteLimit
            ),
            (surfaceID?.utf8.count ?? 0) <= limits.identifierByteLimit else {
            item = nil
            return
        }
        item = MobileNotificationFeedListItem(
            id: id,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            title: try mobileNotificationFeedListString(
                from: container,
                forKey: .title,
                limitedToUTF8Bytes: limits.titleByteLimit
            ),
            subtitle: try mobileNotificationFeedListOptionalString(
                from: container,
                forKey: .subtitle,
                limitedToUTF8Bytes: limits.subtitleByteLimit
            ),
            body: try mobileNotificationFeedListString(
                from: container,
                forKey: .body,
                limitedToUTF8Bytes: limits.bodyByteLimit
            ),
            createdAt: Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt)),
            isRead: try container.decode(Bool.self, forKey: .isRead),
            retargetsToLiveSurfaceOwner: try container.decodeIfPresent(
                Bool.self,
                forKey: .retargetsToLiveSurfaceOwner
            ) ?? false,
            workspaceTitle: try mobileNotificationFeedListOptionalString(
                from: container,
                forKey: .workspaceTitle,
                limitedToUTF8Bytes: limits.metadataByteLimit
            ),
            surfaceTitle: try mobileNotificationFeedListOptionalString(
                from: container,
                forKey: .surfaceTitle,
                limitedToUTF8Bytes: limits.metadataByteLimit
            ),
            // SUPERMUX:begin notification-feed-project-wire
            // Bounded like every other decoded string: the name is clamped and
            // an over-long id drops the project (never the whole row — losing
            // a notification over a bad avatar would be the worse failure).
            project: try Self.supermuxBoundedProject(
                from: container,
                limits: limits
            )
            // SUPERMUX:end notification-feed-project-wire
        )
    }
}

// SUPERMUX:begin notification-feed-project-wire
private extension MobileNotificationFeedListBoundedItem {
    /// Decodes and bounds the additive project field.
    ///
    /// Returns `nil` — degrading the row to its project-less form — when the field
    /// is absent, malformed, or carries an over-long identifier. A row is never
    /// dropped for a bad project: the notification itself is what the user needs.
    static func supermuxBoundedProject(
        from container: KeyedDecodingContainer<CodingKeys>,
        limits: MobileNotificationFeedListStringLimits
    ) throws -> SupermuxNotificationProject? {
        guard let decoded = try? container.decodeIfPresent(
            SupermuxNotificationProject.self,
            forKey: .project
        ) else { return nil }
        guard decoded.id.utf8.count <= limits.identifierByteLimit,
              !decoded.id.isEmpty else { return nil }
        var bounded = decoded
        bounded.name = mobileNotificationFeedListString(
            decoded.name,
            limitedToUTF8Bytes: limits.metadataByteLimit
        )
        if let colorHex = decoded.colorHex, colorHex.utf8.count > limits.metadataByteLimit {
            // Drop malformed decoration rather than truncating it into a different
            // potentially-valid color. The notification row itself stays intact.
            bounded.colorHex = nil
        }
        if let etag = decoded.iconETag, etag.utf8.count > limits.identifierByteLimit {
            bounded.iconETag = nil
        }
        if let symbol = decoded.iconSymbol, symbol.utf8.count > limits.metadataByteLimit {
            bounded.iconSymbol = nil
        }
        return bounded
    }
}
// SUPERMUX:end notification-feed-project-wire

private func mobileNotificationFeedListIdentityString(
    from container: KeyedDecodingContainer<MobileNotificationFeedListBoundedItem.CodingKeys>,
    forKey key: MobileNotificationFeedListBoundedItem.CodingKeys,
    limitedToUTF8Bytes maxBytes: Int
) throws -> String? {
    let value = try container.decode(String.self, forKey: key)
    guard value.utf8.count <= maxBytes else { return nil }
    return value
}

private func mobileNotificationFeedListString(
    from container: KeyedDecodingContainer<MobileNotificationFeedListBoundedItem.CodingKeys>,
    forKey key: MobileNotificationFeedListBoundedItem.CodingKeys,
    limitedToUTF8Bytes maxBytes: Int
) throws -> String {
    try mobileNotificationFeedListString(
        container.decode(String.self, forKey: key),
        limitedToUTF8Bytes: maxBytes
    )
}

private func mobileNotificationFeedListOptionalString(
    from container: KeyedDecodingContainer<MobileNotificationFeedListBoundedItem.CodingKeys>,
    forKey key: MobileNotificationFeedListBoundedItem.CodingKeys,
    limitedToUTF8Bytes maxBytes: Int
) throws -> String? {
    guard let value = try container.decodeIfPresent(String.self, forKey: key) else {
        return nil
    }
    return mobileNotificationFeedListString(value, limitedToUTF8Bytes: maxBytes)
}

private func mobileNotificationFeedListString(_ value: String, limitedToUTF8Bytes maxBytes: Int) -> String {
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

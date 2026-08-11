import Foundation

/// A native iPhone push emitted directly by the paired Supermux Mac.
public struct SupermuxPhonePushMessage: Sendable, Equatable {
    /// The notification operation represented by the payload.
    public enum Kind: Sendable, Equatable {
        /// Presents a visible terminal notification.
        case notify
        /// Removes delivered banners and updates the app badge without presenting UI.
        case dismiss
    }

    /// The operation represented by this message.
    public let kind: Kind
    /// The visible notification title.
    public let title: String
    /// The visible notification subtitle.
    public let subtitle: String
    /// The visible notification body.
    public let body: String
    /// Whether the delivered notification offers inline text reply.
    public let acceptsTextReply: Bool
    /// The source workspace identifier.
    public let workspaceID: String?
    /// The source surface identifier.
    public let surfaceID: String?
    /// Whether a moved surface may resolve outside ``workspaceID``.
    public let retargetsToLiveSurfaceOwner: Bool
    /// The Mac that emitted the notification.
    public let macDeviceID: String?
    /// The stable Mac-side notification identifier.
    public let notificationID: String?
    /// Notification identifiers removed by a dismiss message.
    public let dismissedIDs: [String]
    /// The authoritative unread count applied to the iOS app icon.
    public let badgeCount: Int
    /// Whether terminal text should be replaced with generic copy.
    public let hideContent: Bool

    /// Creates a directly delivered phone-push message.
    public init(
        kind: Kind,
        title: String = "",
        subtitle: String = "",
        body: String = "",
        acceptsTextReply: Bool = false,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        retargetsToLiveSurfaceOwner: Bool = true,
        macDeviceID: String? = nil,
        notificationID: String? = nil,
        dismissedIDs: [String] = [],
        badgeCount: Int,
        hideContent: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.acceptsTextReply = acceptsTextReply
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.macDeviceID = macDeviceID
        self.notificationID = notificationID
        self.dismissedIDs = dismissedIDs
        self.badgeCount = badgeCount
        self.hideContent = hideContent
    }
}

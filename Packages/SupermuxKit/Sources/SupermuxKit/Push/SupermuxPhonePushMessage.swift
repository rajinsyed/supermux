import Foundation
public import SupermuxMobileCore

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
    /// The supermux project the notification's workspace belongs to, or `nil`.
    ///
    /// Travels so the phone can render the project's avatar and name on the
    /// banner and group a project's notifications together — the whole point of
    /// a push you can triage from the lock screen without opening anything.
    ///
    /// The name is clamped by ``projectNameByteLimit`` before it is encoded:
    /// the payload's truncation ladder only shrinks body/subtitle/title, so an
    /// unbounded project name would silently eat the terminal output's budget.
    public let project: SupermuxNotificationProject?
    /// The workspace/tab title the notification fired in, for the banner's
    /// provenance line. Clamped by ``tabNameByteLimit`` for the same reason.
    public let tabName: String?

    /// Maximum UTF-8 bytes of ``SupermuxNotificationProject/name`` that ride in
    /// a push payload.
    public static let projectNameByteLimit = 64
    /// Maximum UTF-8 bytes of ``tabName`` that ride in a push payload.
    public static let tabNameByteLimit = 64

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
        hideContent: Bool = false,
        project: SupermuxNotificationProject? = nil,
        tabName: String? = nil
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
        self.project = project.map {
            var bounded = $0
            bounded.name = Self.clamped($0.name, toUTF8Bytes: Self.projectNameByteLimit)
            return bounded
        }
        self.tabName = tabName.map { Self.clamped($0, toUTF8Bytes: Self.tabNameByteLimit) }
    }

    /// The same message with its project decoration removed.
    ///
    /// The escape hatch for a payload that still will not fit after the text
    /// truncation ladder has run: a notification that arrives without its
    /// avatar beats a notification that does not arrive.
    public func withoutProjectDecoration() -> SupermuxPhonePushMessage {
        SupermuxPhonePushMessage(
            kind: kind,
            title: title,
            subtitle: subtitle,
            body: body,
            acceptsTextReply: acceptsTextReply,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            macDeviceID: macDeviceID,
            notificationID: notificationID,
            dismissedIDs: dismissedIDs,
            badgeCount: badgeCount,
            hideContent: hideContent,
            project: nil,
            tabName: nil
        )
    }

    /// Truncates `value` to at most `maxBytes` UTF-8 bytes on a character
    /// boundary, so a clamp can never split a grapheme into mojibake.
    static func clamped(_ value: String, toUTF8Bytes maxBytes: Int) -> String {
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

import CmuxNotifications
import CmuxSettings
import Foundation
// SUPERMUX:begin notification-project-identity
import SupermuxMobileCore
// SUPERMUX:end notification-project-identity

struct TerminalNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let panelId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let correlationKey: String?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    var paneFlash: Bool = true
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    var replyShape: TerminalNotificationReplyShape = .none
    var soundContext: NotificationSoundOverrideContext?
    /// Who emitted the text. Remote origins are clamped to display-only side effects by
    /// the store and surface to hooks as `CMUX_NOTIFICATION_ORIGIN`.
    var origin: TerminalNotificationOrigin = .local
    // SUPERMUX:begin notification-project-identity
    /// The supermux project that owned this notification's workspace when it
    /// fired, or `nil` for a workspace belonging to no project. A frozen
    /// snapshot, not a live reference — history stays readable after a project
    /// is renamed, recolored, or unregistered. Resolved once at delivery by
    /// `SupermuxNotificationProjectResolver`; every surface (panel, banner,
    /// phone feed, push) reads it rather than re-deriving its own.
    var project: SupermuxNotificationProject?
    // SUPERMUX:end notification-project-identity

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        retargetsToLiveSurfaceOwner: Bool = true,
        correlationKey: String? = nil,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        paneFlash: Bool = true,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        replyShape: TerminalNotificationReplyShape = .none,
        soundContext: NotificationSoundOverrideContext? = nil,
        origin: TerminalNotificationOrigin = .local,
        // SUPERMUX:begin notification-project-identity
        // Defaulted so no upstream construction site changes; supermux's
        // delivery path is the only caller that passes a value.
        project: SupermuxNotificationProject? = nil
        // SUPERMUX:end notification-project-identity
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.correlationKey = correlationKey
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.replyShape = replyShape
        self.soundContext = soundContext
        self.origin = origin
        // SUPERMUX:begin notification-project-identity
        self.project = project
        // SUPERMUX:end notification-project-identity
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }

    /// Matches a clear without letting live-owner expansion cross a confined notification's workspace boundary.
    func matchesClear(tabId targetTabId: UUID, liveTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard let targetSurfaceId else {
            let matchesWorkspace = tabId == targetTabId || (retargetsToLiveSurfaceOwner && tabId == liveTabId)
            return matchesWorkspace && surfaceId == nil && panelId == nil
        }
        guard surfaceId == targetSurfaceId || panelId == targetSurfaceId else {
            return false
        }
        // A retargetable notification is owned by the globally unique surface,
        // not by the workspace in which it happened to be stored when it was
        // delivered. This lets a completion clear a banner that was recorded
        // under the pane's previous workspace after a move.
        return retargetsToLiveSurfaceOwner || tabId == targetTabId
    }
}

public import CmuxMobileShellModel
import Foundation

/// Projects Mac-authoritative pane unread state onto one visible mobile pane.
public struct SupermuxMobilePaneUnreadPresentation: Equatable, Sendable {
    /// Whether the paired Mac supports exact pane unread state.
    public let supportsPaneUnreadState: Bool
    /// Whether the visible pane should draw the persistent unread ring.
    public let showsRing: Bool

    /// Creates the unread presentation for one pane in a workspace.
    ///
    /// A supporting Mac sends ``MobileWorkspacePreview/supermuxUnreadPanelIDs``
    /// even when the array is empty. An absent field means the host only supports
    /// workspace-wide unread state, so this presentation stays hidden and lets the
    /// legacy open-workspace read receipt remain in charge.
    ///
    /// - Parameters:
    ///   - workspace: The Mac-authoritative workspace snapshot.
    ///   - panelID: The Mac panel identifier currently visible on the phone.
    public init(
        workspace: MobileWorkspacePreview,
        panelID: String?
    ) {
        guard let unreadPanelIDs = workspace.supermuxUnreadPanelIDs else {
            supportsPaneUnreadState = false
            showsRing = false
            return
        }

        supportsPaneUnreadState = true
        guard let panelID = Self.normalized(panelID) else {
            showsRing = false
            return
        }
        showsRing = unreadPanelIDs.contains { Self.normalized($0) == panelID }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

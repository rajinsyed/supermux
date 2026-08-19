import SwiftUI
import CmuxSettings

struct SupermuxHarnessPanelView: View {
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedSessionContentMaximumWidth = SessionContentWidthSettings.noMaximumWidth
    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedSessionContentAlignment = SessionContentAlignment.center.rawValue
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    /// The same resolved attention colour terminal panes stroke their ring
    /// with, so the harness tick honours the user's pane-flash colour setting.
    @Environment(\.workspaceAttentionColor) private var workspaceAttentionColor
    let panel: SupermuxHarnessPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    /// Item 10: mirrors `TerminalPanelView.hasUnreadNotification`. The harness
    /// pane renders it as an edge tick instead of upstream's outline ring.
    var hasUnreadNotification: Bool = false
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if isVisibleInUI {
                SupermuxHarnessWebRenderer(
                    panel: panel,
                    isFocused: isFocused,
                    backgroundColor: appearance.contentBackgroundColor,
                    theme: AgentSessionWebTheme.resolve(appearance: appearance),
                    sessionContentWidthPresentation: sessionContentWidthPresentation,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .id(panel.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(Double(portalPriority))
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .overlay {
            // Mounted above the WKWebView, hit-testing disabled. Honors the
            // same `unreadPaneRing` setting the terminal ring honors, so one
            // toggle still turns every pane indicator off.
            SupermuxHarnessUnreadIndicator(
                isUnread: hasUnreadNotification && notificationPaneRingEnabled,
                attentionColor: Color(nsColor: workspaceAttentionColor.nsColor)
            )
        }
    }

    private var sessionContentWidthPresentation: SessionContentWidthPresentation {
        SessionContentWidthPresentation(
            storedMaximumWidth: storedSessionContentMaximumWidth,
            storedAlignment: storedSessionContentAlignment
        )
    }
}

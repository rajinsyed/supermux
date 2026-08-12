import SwiftUI
import CmuxSettings

struct AgentSessionPanelView: View {
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedSessionContentMaximumWidth = SessionContentWidthSettings.noMaximumWidth
    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedSessionContentAlignment = SessionContentAlignment.center.rawValue
    let panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if isVisibleInUI {
                // SUPERMUX:begin supermux-claude-harness-panel
                // Claude Code renders through the fork's native harness; codex
                // and opencode keep the upstream webview renderer.
                if SupermuxClaudeHarness.handles(panel) {
                    SupermuxClaudeHarnessMount(
                        panel: panel,
                        isFocused: isFocused,
                        appearance: appearance,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                    .id(panel.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(Double(portalPriority))
                } else {
                // SUPERMUX:end supermux-claude-harness-panel
                AgentSessionWebRenderer(
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
                // SUPERMUX:begin supermux-claude-harness-panel
                }
                // SUPERMUX:end supermux-claude-harness-panel
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }

    private var sessionContentWidthPresentation: SessionContentWidthPresentation {
        SessionContentWidthPresentation(
            storedMaximumWidth: storedSessionContentMaximumWidth,
            storedAlignment: storedSessionContentAlignment
        )
    }
}

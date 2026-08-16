import AppKit
import CmuxFoundation
import Foundation
import SupermuxKit
import SupermuxZeronUI
import SwiftUI

/// Mounts the native Claude Code harness inside the upstream agent-session
/// panel (the `supermux-claude-harness-panel` fence).
///
/// Deliberately **not** `@StateObject`/`@State`: the model is resolved from
/// ``SupermuxClaudeHarnessRegistry`` by panel id, because the upstream panel
/// view unmounts this whole subtree when the tab is hidden and a view-owned
/// model would take the running `claude` process with it.
struct SupermuxClaudeHarnessMount: View {
    let panel: AgentSessionPanel
    let isFocused: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @EnvironmentObject private var tabManager: TabManager
    /// The registry-owned model, resolved in `onAppear` — never in `body`:
    /// creating (or rewiring) it during render is a stateful registry write,
    /// which the fork's snapshot-boundary rule forbids from body evaluation.
    @State private var model: SupermuxHarnessViewModel?

    var body: some View {
        Group {
            if let model {
                SupermuxHarnessView(
                    model: model,
                    theme: SupermuxZeronTheme(isDark: isDark),
                    // Read lazily, never at panel construction: upstream adopts
                    // the persisted id inside `applySessionPanelMetadata`,
                    // which runs after `newAgentSessionSurface` returns.
                    stableSurfaceID: panel.stableSurfaceId
                )
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onRequestPanelFocus)
        .onAppear(perform: resolveModel)
    }

    private func resolveModel() {
        model = SupermuxClaudeHarnessRegistry.shared.ensureModel(
            panelID: panel.id,
            workingDirectory: panel.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            onDerivedTitle: { [panelID = panel.id, workspaceId = panel.workspaceId, weak tabManager] title in
                guard let workspace = tabManager?.tabs.first(where: {
                    $0.id == workspaceId
                }) else { return }
                _ = workspace.setPanelCustomTitle(
                    panelId: panelID, title: title, source: .auto
                )
            }
        )
    }

    /// The ONE input the zeron pane takes from the panel's appearance.
    ///
    /// The pane used to derive its whole palette from `PanelAppearance` (the
    /// Ghostty theme's background, foreground, accent and content background)
    /// so a native Claude panel matched a webview Codex panel under any Ghostty
    /// theme. That premise is gone with the zeron port: zeron is a FIXED design
    /// system with a 44-token palette in exactly two appearances, and reshading
    /// it per terminal theme is precisely what the port replaces.
    ///
    /// **Deliberate consequence:** a Codex webview panel beside a Claude panel
    /// now looks different. That is the requested behavior, not a regression.
    /// Only the light/dark axis still follows the panel, so a light Ghostty
    /// theme still yields a light chat pane.
    private var isDark: Bool {
        !appearance.backgroundColor.isLightColor
    }
}

/// The fork-owned entry points for the native harness.
///
/// Every upstream fence calls into this type rather than into SupermuxKit
/// directly, so the fenced lines stay one-liners and the real policy (which
/// provider is handled, how a session is torn down, how a panel is opened) lives
/// in fork-owned code.
///
/// lint:allow namespace-type — fence-facing façade, no state of its own.
/// (lint:allow)
@MainActor
enum SupermuxClaudeHarness {
    /// Whether the fork renders this agent-session panel natively.
    ///
    /// Codex and OpenCode keep the upstream webview; only Claude Code is
    /// replaced, because only Claude Code has a native protocol host here.
    static func handles(_ panel: AgentSessionPanel) -> Bool {
        panel.currentProviderID == .claude
    }

    /// Teardown for one panel (the `supermux-claude-harness-lifecycle` fence).
    static func closeSession(panelID: UUID) {
        SupermuxClaudeHarnessRegistry.shared.close(panelID: panelID)
    }

    /// Terminates every live harness session (app shutdown).
    static func closeAllSessions() async {
        await SupermuxClaudeHarnessRegistry.shared.closeAll()
    }

    /// Synchronous best-effort teardown from `applicationWillTerminate`
    /// (the `supermux-claude-harness-terminate` fence): every live child gets
    /// stdin EOF + SIGTERM without awaiting the actor.
    static func terminateAllForAppShutdown() {
        SupermuxClaudeHarnessRegistry.shared.sessions.terminateAllForAppShutdown()
    }
}

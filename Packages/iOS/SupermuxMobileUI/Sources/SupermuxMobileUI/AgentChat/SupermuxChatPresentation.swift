#if os(iOS)
public import CmuxAgentChatUI
public import SwiftUI

/// Builds the fork's ``ChatPresentation``: supermux rows, placeholders, and
/// composer, rendered inside upstream's transcript and keyboard machinery.
///
/// This is the single place the redesign is switched on. Hosts call
/// ``SwiftUI/View/supermuxAgentChat(isEnabled:)``; passing `false` leaves the
/// surface byte-identical to upstream, which is what an unpaired phone or a
/// fork phone talking to an upstream Mac renders.
public extension ChatPresentation {
    /// Bump when the fork's visual configuration changes in a way that leaves
    /// row values identical; the transcript folds this into its reload
    /// decision, so stale cells cannot survive a restyle.
    private static var visualRevision: String { "supermux.chat.v1" }

    /// Creates the presentation.
    ///
    /// - Parameter theme: Tokens applied to every fork-rendered surface.
    /// - Returns: The renderers to install on the chat surface.
    @MainActor
    static func supermux(theme: SupermuxChatTheme = SupermuxChatTheme()) -> ChatPresentation {
        ChatPresentation(
            identity: visualRevision,
            row: { row, actions in
                AnyView(
                    SupermuxChatRowView(row: row, actions: actions)
                        .equatable()
                        .environment(\.supermuxChatTheme, theme)
                )
            },
            placeholder: { placeholder in
                AnyView(
                    SupermuxChatPlaceholderView(placeholder: placeholder)
                        .environment(\.supermuxChatTheme, theme)
                )
            },
            composer: { context in
                AnyView(
                    SupermuxChatComposer(
                        agentState: context.agentState,
                        agentKind: context.agentKind,
                        isConnected: context.isConnected,
                        draft: context.draft,
                        accessoryLeadingShortcuts: context.accessoryLeadingShortcuts,
                        accessoryShortcuts: context.accessoryShortcuts,
                        onSend: context.onSend,
                        onInterrupt: context.onInterrupt,
                        onOpenTerminal: context.onOpenTerminal
                    )
                    .environment(\.supermuxChatTheme, theme)
                )
            }
        )
    }
}

public extension View {
    /// Installs the supermux agent-chat design on the chat surface below.
    ///
    /// - Parameters:
    ///   - isEnabled: When `false`, upstream's own chat UI renders unchanged.
    ///   - theme: Tokens for the fork surfaces.
    /// - Returns: The modified view.
    @MainActor
    func supermuxAgentChat(
        isEnabled: Bool = true,
        theme: SupermuxChatTheme = SupermuxChatTheme()
    ) -> some View {
        chatPresentation(
            isEnabled ? ChatPresentation.supermux(theme: theme) : nil
        )
    }
}
#endif

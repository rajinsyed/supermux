// SUPERMUX:begin agent-chat-presentation-seam
//
// Fork-owned file inside an upstream package (same precedent as the other
// whole-file fork additions in SUPERMUX-TOUCHPOINTS.md): it adds a rendering
// seam without editing any upstream logic.
//
// WHY A SEAM AND NOT A REWRITE. The supermux agent-chat redesign replaces the
// row visuals and the composer, but deliberately reuses upstream's UIKit
// keyboard-tracking controller, transcript table (anchor restoration, at-bottom
// tracking, streaming height behavior), artifact viewer, history paging, and
// detail sheets — the parts that are hard to reproduce and easy to regress.
// So the fork injects two view builders and upstream keeps owning mechanics.
//
// WHY AN ENVIRONMENT VALUE IS NOT ENOUGH ON ITS OWN. The transcript renders
// cells through `UIHostingConfiguration`, which starts a FRESH environment —
// arbitrary values set above `ChatScreen` do not cross that boundary. Upstream
// already re-injects five values per cell in
// `ChatTranscriptTableConfiguration.view(for:tableWidth:)`; the presentation
// must be re-injected in exactly the same place, which is what the fenced hook
// in that file does. Without it the seam compiles and silently renders
// upstream's rows.
import CmuxAgentChat
import SwiftUI

/// Fork-supplied renderers for the chat surface.
///
/// A value of closures rather than a protocol: a protocol with associated
/// `View` types cannot be stored in the environment without another erasure
/// layer, and adding a requirement would break every conformer. New optional
/// closures can be added here without touching call sites.
///
/// A `nil` presentation means "render exactly upstream", so every host that
/// does not opt in — demos, previews, tests, an unpaired phone — is unaffected.
@MainActor
public struct ChatPresentation {
    /// Renders one transcript row, replacing ``ChatTranscriptRowView``.
    public var row: (ChatTranscriptRow, ChatRowActions) -> AnyView

    /// Renders a non-message transcript state (empty, loading, failure,
    /// truncated history, typing).
    ///
    /// These are synthetic table items, not ``ChatTranscriptRow`` values, so
    /// the row closure can never reach them; without this the redesign would
    /// keep upstream's empty and loading states.
    public var placeholder: (ChatTranscriptPlaceholder) -> AnyView

    /// Renders the composer, replacing ``ChatComposerView``.
    public var composer: (ChatComposerContext) -> AnyView

    /// Identity of this presentation's visual configuration.
    ///
    /// The transcript folds this into its reload decision, so a theme change
    /// re-renders cells that are otherwise value-identical.
    public var identity: String

    /// Creates a presentation.
    ///
    /// - Parameters:
    ///   - identity: Visual-configuration identity, folded into reloads.
    ///   - row: Renders one transcript row.
    ///   - composer: Renders the composer.
    public init(
        identity: String,
        row: @escaping (ChatTranscriptRow, ChatRowActions) -> AnyView,
        placeholder: @escaping (ChatTranscriptPlaceholder) -> AnyView,
        composer: @escaping (ChatComposerContext) -> AnyView
    ) {
        self.identity = identity
        self.row = row
        self.placeholder = placeholder
        self.composer = composer
    }
}

/// A non-message transcript state the presentation may restyle.
@MainActor
public enum ChatTranscriptPlaceholder {
    /// Older history is being paged in at the head.
    case loadingMore
    /// Paging stopped at the Mac's cache head.
    case historyTruncated
    /// The first page failed; carries the retry action.
    case loadFailed(retry: () -> Void)
    /// The session has no messages.
    case empty
    /// The first page has not arrived yet.
    case initialLoading
    /// The agent is working.
    case typing(ChatAgentState)
}

/// Everything a replacement composer needs, without a store reference.
///
/// Mirrors the arguments upstream passes to ``ChatComposerView`` so the fork
/// composer is a drop-in, and keeps the snapshot boundary intact: values and
/// closures only.
@MainActor
public struct ChatComposerContext {
    /// Live agent presence.
    public let agentState: ChatAgentState
    /// Which agent is running; names the placeholder.
    public let agentKind: ChatAgentKind
    /// Whether this is a plain-terminal session rather than an agent session.
    public let isTerminal: Bool
    /// Whether the transport is currently connected.
    public let isConnected: Bool
    /// Host-provided fixed shortcut row items.
    public let accessoryLeadingShortcuts: [ChatAccessoryShortcut]
    /// Host-provided shortcut row items.
    public let accessoryShortcuts: [ChatAccessoryShortcut]
    /// Host-owned composer draft.
    public let draft: Binding<String>
    /// Sends text plus staged attachments.
    public let onSend: (String, [ChatOutboundAttachment]) -> Void
    /// Interrupts the current turn; `true` means hard.
    public let onInterrupt: (Bool) -> Void
    /// Opens the session's raw terminal.
    public let onOpenTerminal: () -> Void

    /// Creates a composer context.
    public init(
        agentState: ChatAgentState,
        agentKind: ChatAgentKind,
        isTerminal: Bool,
        isConnected: Bool,
        accessoryLeadingShortcuts: [ChatAccessoryShortcut],
        accessoryShortcuts: [ChatAccessoryShortcut],
        draft: Binding<String>,
        onSend: @escaping (String, [ChatOutboundAttachment]) -> Void,
        onInterrupt: @escaping (Bool) -> Void,
        onOpenTerminal: @escaping () -> Void
    ) {
        self.agentState = agentState
        self.agentKind = agentKind
        self.isTerminal = isTerminal
        self.isConnected = isConnected
        self.accessoryLeadingShortcuts = accessoryLeadingShortcuts
        self.accessoryShortcuts = accessoryShortcuts
        self.draft = draft
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onOpenTerminal = onOpenTerminal
    }
}

extension EnvironmentValues {
    /// The active fork presentation; `nil` renders upstream's own views.
    @Entry public var chatPresentation: ChatPresentation?
}

public extension View {
    /// Installs a fork presentation for the chat surface beneath this view.
    ///
    /// - Parameter presentation: The renderers, or `nil` for upstream's.
    /// - Returns: The modified view.
    func chatPresentation(_ presentation: ChatPresentation?) -> some View {
        environment(\.chatPresentation, presentation)
    }
}
// SUPERMUX:end agent-chat-presentation-seam

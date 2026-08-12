public import SwiftUI

/// The chat composer: an auto-growing field, the slash-command autocomplete,
/// and one primary button that is Send or Stop.
///
/// Value-only, like every other row on this screen: the send and stop actions
/// arrive as closures, so the composer never holds a store.
public struct SupermuxClaudeComposer: View {
    @Binding private var draft: String
    private let isSending: Bool
    private let isWorking: Bool
    private let slashCommands: [String]
    private let send: @MainActor (String) -> Void
    private let stop: @MainActor () -> Void

    @FocusState private var isFocused: Bool

    /// Creates the composer.
    /// - Parameters:
    ///   - draft: The composer's text.
    ///   - isSending: Whether a send is on the wire.
    ///   - isWorking: Whether the session is running a turn.
    ///   - slashCommands: Command names from `claude.options`.
    ///   - send: Sends the trimmed draft.
    ///   - stop: Interrupts the running turn.
    public init(
        draft: Binding<String>,
        isSending: Bool,
        isWorking: Bool,
        slashCommands: [String],
        send: @escaping @MainActor (String) -> Void,
        stop: @escaping @MainActor () -> Void
    ) {
        self._draft = draft
        self.isSending = isSending
        self.isWorking = isWorking
        self.slashCommands = slashCommands
        self.send = send
        self.stop = stop
    }

    public var body: some View {
        let suggestions = SupermuxClaudeComposerPresentation.slashSuggestions(
            draft: draft,
            commands: slashCommands
        )
        VStack(spacing: 0) {
            if !suggestions.isEmpty {
                autocomplete(suggestions)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    String(
                        localized: "supermux.claude.composer.placeholder",
                        defaultValue: "Message Claude",
                        bundle: .module
                    ),
                    text: $draft,
                    axis: .vertical
                )
                .font(SupermuxClaudeStyle.body())
                .lineLimit(1 ... 6)
                .focused($isFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(
                    cornerRadius: SupermuxClaudeStyle.bubbleCornerRadius,
                    style: .continuous
                ))

                primaryButton
            }
            .padding(.horizontal, SupermuxClaudeStyle.horizontalMargin)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var primaryButton: some View {
        // Stop takes the primary slot only when there is nothing to send, so
        // a tap aimed at Send while a turn runs still queues the prompt
        // Mac-side rather than cancelling the turn.
        if SupermuxClaudeComposerPresentation.showsStop(isWorking: isWorking, draft: draft) {
            Button(role: .destructive) {
                stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "supermux.claude.stop",
                defaultValue: "Stop",
                bundle: .module
            ))
        } else {
            Button {
                send(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(!SupermuxClaudeComposerPresentation.canSend(
                draft: draft,
                isSending: isSending
            ))
            .accessibilityLabel(String(
                localized: "supermux.claude.send",
                defaultValue: "Send",
                bundle: .module
            ))
        }
    }

    private func autocomplete(_ suggestions: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { command in
                    Button {
                        draft = SupermuxClaudeComposerPresentation.accept(command: command)
                    } label: {
                        Text(command)
                            .font(SupermuxClaudeStyle.mono(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SupermuxClaudeStyle.horizontalMargin)
            .padding(.vertical, 6)
        }
    }
}

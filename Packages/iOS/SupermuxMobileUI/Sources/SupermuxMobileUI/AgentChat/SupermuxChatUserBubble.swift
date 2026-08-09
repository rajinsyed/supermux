public import CmuxAgentChat
public import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The user's own prompt: a trailing-aligned bubble.
///
/// The only bubble on the surface. Agent prose is full-bleed text, so the
/// bubble is what makes a prompt scannable when skimming back through a long
/// session — it marks "this is where I asked for something".
public struct SupermuxChatUserBubble: View {
    private let text: String
    private let timestamp: Date
    private let showsTimestamp: Bool
    private let onCopied: () -> Void

    @Environment(\.supermuxChatTheme) private var theme

    /// Creates a user bubble.
    ///
    /// - Parameters:
    ///   - text: The prompt text.
    ///   - timestamp: When the prompt was sent.
    ///   - showsTimestamp: Whether to caption the bubble with its time.
    ///   - onCopied: Reports a completed copy so the host can confirm it.
    public init(
        text: String,
        timestamp: Date,
        showsTimestamp: Bool,
        onCopied: @escaping () -> Void = {}
    ) {
        self.text = text
        self.timestamp = timestamp
        self.showsTimestamp = showsTimestamp
        self.onCopied = onCopied
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: theme.outgoingLeadingGutter)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.supermuxChatBody())
                    .foregroundStyle(theme.outgoingText)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        theme.outgoingFill,
                        in: .rect(cornerRadius: theme.bubbleCornerRadius, style: .continuous)
                    )
                    .contextMenu {
                        Button(action: copy) {
                            Label(Self.copyTitle, systemImage: "doc.on.doc")
                        }
                    }

                if showsTimestamp {
                    Text(timestamp.formatted(.dateTime.hour().minute()))
                        .font(.supermuxChatCaption())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(Self.copyTitle), copy)
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        onCopied()
        #endif
    }

    static let copyTitle = String(
        localized: "supermux.chat.copy",
        defaultValue: "Copy",
        bundle: .module
    )
}

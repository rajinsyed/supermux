#if os(iOS)
public import CmuxAgentChat
public import CmuxAgentChatUI
public import SwiftUI

/// The transcript's non-message states: empty, loading, failure, truncated
/// history, and the working indicator.
///
/// The empty state is the first thing a user sees when they open a fresh
/// session, so it carries the surface's whole character in one screen: a
/// centered mark, a question rather than a label, and nothing else.
public struct SupermuxChatPlaceholderView: View {
    private let placeholder: ChatTranscriptPlaceholder

    @Environment(\.supermuxChatTheme) private var theme

    /// Creates a placeholder view.
    ///
    /// - Parameter placeholder: The state to render.
    public init(placeholder: ChatTranscriptPlaceholder) {
        self.placeholder = placeholder
    }

    public var body: some View {
        switch placeholder {
        case .loadingMore:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)

        case .historyTruncated:
            Text(
                String(
                    localized: "supermux.chat.history.truncated",
                    defaultValue: "Earlier history is on your Mac",
                    bundle: .module
                )
            )
            .font(.supermuxChatCaption())
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)

        case .loadFailed(let retry):
            VStack(spacing: 12) {
                Text(
                    String(
                        localized: "supermux.chat.loadFailed",
                        defaultValue: "Couldn't load this conversation",
                        bundle: .module
                    )
                )
                .font(.supermuxChatSubheadline())
                .foregroundStyle(.secondary)
                Button(action: retry) {
                    Text(
                        String(
                            localized: "supermux.chat.retry",
                            defaultValue: "Retry",
                            bundle: .module
                        )
                    )
                    .font(.supermuxChatSubheadline(.semibold))
                    .foregroundStyle(theme.outgoingText)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(theme.accent, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SupermuxChatTranscriptRetry")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)

        case .empty:
            emptyState

        case .initialLoading:
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)

        case .typing(let agentState):
            SupermuxChatShimmerText(text: workingLabel(agentState))
                // Fixed height so the indicator never reflows the rows above
                // it while assistant deltas stream in.
                .frame(minHeight: 24, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.outgoingText)
                .frame(width: 52, height: 52)
                .background(
                    theme.accent,
                    in: .rect(cornerRadius: 17, style: .continuous)
                )
            Text(
                String(
                    localized: "supermux.chat.empty.title",
                    defaultValue: "What should we work on?",
                    bundle: .module
                )
            )
            .font(.supermuxChatTitle())
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 64)
    }

    private func workingLabel(_ agentState: ChatAgentState) -> String {
        if case .needsInput = agentState {
            return String(
                localized: "supermux.chat.working.needsInput",
                defaultValue: "Waiting for you",
                bundle: .module
            )
        }
        return String(
            localized: "supermux.chat.working",
            defaultValue: "Working",
            bundle: .module
        )
    }
}
#endif

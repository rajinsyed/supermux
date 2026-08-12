import SwiftUI
import CmuxFoundation

/// Extended thinking, collapsed to a one-line preview until expanded.
///
/// Thinking is high-volume and usually skimmed, so the collapsed state shows
/// only the newest line — which also makes the streaming case read as live
/// progress rather than as a growing wall of text.
struct SupermuxHarnessThinkingRow: View {
    let rowID: String
    let text: String
    let isStreaming: Bool
    let theme: SupermuxHarnessTheme

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing6) {
            Button {
                withAnimation(reduceMotion ? nil : SupermuxHarnessTokens.disclosure) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: SupermuxHarnessTokens.spacing6) {
                    Image(systemName: "brain")
                        .font(.system(size: SupermuxHarnessTokens.caption))
                        .foregroundStyle(theme.mutedText)
                    Text(label)
                        .cmuxFont(size: SupermuxHarnessTokens.footnote, weight: .medium)
                        .foregroundStyle(theme.mutedText)
                    if !isExpanded {
                        Text(preview)
                            .cmuxFont(size: SupermuxHarnessTokens.footnote)
                            .foregroundStyle(theme.mutedText.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: SupermuxHarnessTokens.spacing4)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: SupermuxHarnessTokens.caption2))
                        .foregroundStyle(theme.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .cmuxFont(size: SupermuxHarnessTokens.footnote)
                    .foregroundStyle(theme.softText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SupermuxHarnessTokens.timelineGutter)
            }
        }
        .padding(.vertical, SupermuxHarnessTokens.spacing4)
    }

    private var label: String {
        isStreaming
            ? String(
                localized: "supermux.harness.thinking.active",
                defaultValue: "Thinking…"
            )
            : String(
                localized: "supermux.harness.thinking.label",
                defaultValue: "Thought"
            )
    }

    /// The newest non-empty line: while streaming this reads as live progress.
    private var preview: String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

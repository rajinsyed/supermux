import SwiftUI
import CmuxFoundation

/// The one-line cost/duration/turns summary of a finished turn.
struct SupermuxHarnessResultRow: View {
    let summary: SupermuxHarnessResultSummary
    let theme: SupermuxHarnessTheme

    var body: some View {
        HStack(spacing: SupermuxHarnessTokens.spacing6) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Text("·")
                        .foregroundStyle(theme.mutedText.opacity(0.6))
                        .supermuxHarnessRigidLabel()
                }
                // Every component is a short fixed token ("$0.0321", "2 turns");
                // none may wrap into a one-glyph column when the panel narrows.
                Text(component).supermuxHarnessRigidLabel()
            }
            Spacer(minLength: 0)
        }
        .cmuxFont(size: SupermuxHarnessTokens.caption, monospacedDigit: true)
        .foregroundStyle(summary.isError ? theme.danger : theme.mutedText)
        .padding(.leading, SupermuxHarnessTokens.timelineGutter)
        .padding(.vertical, SupermuxHarnessTokens.spacing2)
    }

    private var components: [String] {
        var parts: [String] = []
        if let cost = summary.totalCostUSD {
            parts.append(String(format: "$%.4f", cost))
        }
        if let duration = summary.durationMs {
            parts.append(Self.durationText(milliseconds: duration))
        }
        if let turns = summary.numTurns {
            parts.append(
                String(
                    format: String(
                        localized: "supermux.harness.cost.turns",
                        defaultValue: "%lld turns"
                    ),
                    Int64(turns)
                )
            )
        }
        if let input = summary.inputTokens, let output = summary.outputTokens {
            parts.append("↑\(input) ↓\(output)")
        }
        if summary.terminalReason == "aborted_streaming" {
            parts.append(
                String(
                    localized: "supermux.harness.cost.interrupted",
                    defaultValue: "interrupted"
                )
            )
        }
        return parts
    }

    static func durationText(milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }
}

/// A launcher/process/protocol notice inside the transcript.
struct SupermuxHarnessNoticeRow: View {
    let notice: SupermuxHarnessNotice
    let theme: SupermuxHarnessTheme

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            Button {
                guard notice.detail != nil else { return }
                withAnimation(reduceMotion ? nil : SupermuxHarnessTokens.disclosure) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: SupermuxHarnessTokens.spacing6) {
                    Image(systemName: symbol)
                        .font(.system(size: SupermuxHarnessTokens.caption))
                        .foregroundStyle(color)
                        .frame(width: SupermuxHarnessTokens.timelineGutter)
                    Text(notice.title)
                        .cmuxFont(size: SupermuxHarnessTokens.footnote)
                        .foregroundStyle(color)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: SupermuxHarnessTokens.spacing4)
                    if notice.detail != nil {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: SupermuxHarnessTokens.caption2))
                            .foregroundStyle(theme.mutedText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(notice.detail == nil)

            if isExpanded, let detail = notice.detail {
                Text(detail)
                    .cmuxFont(size: SupermuxHarnessTokens.caption, design: .monospaced)
                    .foregroundStyle(theme.softText)
                    .textSelection(.enabled)
                    .padding(SupermuxHarnessTokens.spacing6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(
                            cornerRadius: SupermuxHarnessTokens.fileBoxRadius,
                            style: .continuous
                        )
                        .fill(theme.surface)
                    )
            }
        }
        .padding(.vertical, SupermuxHarnessTokens.spacing2)
    }

    private var symbol: String {
        switch notice.severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var color: Color {
        switch notice.severity {
        case .info: return theme.mutedText
        case .warning: return theme.toolAccent
        case .error: return theme.danger
        }
    }
}

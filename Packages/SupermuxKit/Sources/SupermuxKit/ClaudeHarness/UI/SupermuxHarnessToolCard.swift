import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness

/// One tool invocation, humanized — deliberately *quiet*.
///
/// remodex renders tool rows as bare `HStack`s with secondary text, no card
/// chrome: a turn that reads twelve files must recede beneath the assistant's
/// prose, not become twelve bordered boxes pushing the answer off-screen.
/// Status is carried by the glyph's colour only — running amber, done
/// secondary, failed red badge — never by a badge row or status text.
struct SupermuxHarnessToolCard: View {
    let call: SupermuxHarnessToolCall
    let theme: SupermuxHarnessTheme

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing6) {
            header
            if isExpanded {
                detail
            }
            if let todos = todosIfPresent {
                SupermuxHarnessTodoCard(todos: todos, theme: theme)
            }
            if let diff = call.diff {
                SupermuxHarnessDiffCard(
                    diff: diff, filePath: call.subject, theme: theme
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : SupermuxHarnessTokens.disclosure) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: SupermuxHarnessTokens.spacing6) {
                Image(systemName: SupermuxHarnessToolIcon.symbol(for: call.name))
                    .font(.system(size: SupermuxHarnessTokens.footnote))
                    .foregroundStyle(statusColor)
                    .frame(width: SupermuxHarnessTokens.timelineGutter, alignment: .center)
                Text(label)
                    .cmuxFont(size: SupermuxHarnessTokens.subheadline)
                    .foregroundStyle(theme.mutedText)
                    .supermuxHarnessRigidLabel()
                if let subject = call.subject {
                    // The command is the only thing allowed to lose width here;
                    // it must NOT carry layoutPriority, or it takes the width
                    // from the label and wraps that into a 1-glyph column.
                    Text(subject)
                        .cmuxFont(size: SupermuxHarnessTokens.footnote, design: .monospaced)
                        .foregroundStyle(theme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if call.status == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: SupermuxHarnessTokens.footnote))
                        .foregroundStyle(theme.danger)
                }
                // Chevron next to the command, not pinned far right (remodex's
                // explicit choice); it only shows when there is detail to open.
                if hasDetail {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: SupermuxHarnessTokens.caption2, weight: .semibold))
                        .foregroundStyle(theme.mutedText)
                        .padding(.leading, SupermuxHarnessTokens.spacing2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // Tool rows update often while streaming; keep the subtree static
            // so in-place updates never flash the whole row (remodex's guard —
            // it applies more strongly here with a 16ms flush cadence).
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasDetail)
    }

    @ViewBuilder
    private var detail: some View {
        if let resultText = call.resultText, !resultText.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(resultText)
                    .cmuxFont(size: SupermuxHarnessTokens.caption, design: .monospaced)
                    .foregroundStyle(
                        call.status == .failed ? theme.danger : theme.softText
                    )
                    .textSelection(.enabled)
                    .padding(SupermuxHarnessTokens.spacing6)
            }
            .frame(maxHeight: 220)
            .background(
                RoundedRectangle(
                    cornerRadius: SupermuxHarnessTokens.fileBoxRadius, style: .continuous
                )
                .fill(theme.pageIsTransparent ? theme.surface : theme.surfaceElevated)
            )
            .padding(.leading, SupermuxHarnessTokens.timelineGutter)
        }
    }

    private var hasDetail: Bool {
        !(call.resultText ?? "").isEmpty
    }

    /// TodoWrite renders as a plan card instead of a raw JSON payload.
    private var todosIfPresent: [SupermuxHarnessTodo]? {
        let todos = call.todos
        return todos.isEmpty ? nil : todos
    }

    private var label: String {
        switch call.status {
        case .running: return call.labels.running
        case .succeeded, .failed: return call.labels.done
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .running: return theme.toolAccent
        case .succeeded: return theme.mutedText
        case .failed: return theme.danger
        }
    }
}

/// A collapsed run of consecutive completed tool calls.
///
/// A turn that reads twelve files should be one line the user can open, not
/// twelve rows pushing the answer off-screen.
struct SupermuxHarnessToolBurstGroup: View {
    let calls: [SupermuxHarnessToolCall]
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
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: SupermuxHarnessTokens.footnote))
                        .foregroundStyle(theme.mutedText)
                        .frame(width: SupermuxHarnessTokens.timelineGutter)
                    Text(
                        String(
                            format: String(
                                localized: "supermux.harness.tool.burst",
                                defaultValue: "%lld tool calls"
                            ),
                            Int64(calls.count)
                        )
                    )
                    .cmuxFont(size: SupermuxHarnessTokens.subheadline)
                    .foregroundStyle(theme.mutedText)
                    .supermuxHarnessRigidLabel()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: SupermuxHarnessTokens.caption2, weight: .semibold))
                        .foregroundStyle(theme.mutedText)
                        .padding(.leading, SupermuxHarnessTokens.spacing2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(calls) { call in
                    SupermuxHarnessToolCard(call: call, theme: theme)
                }
            }
        }
    }
}

/// Tool-name → SF Symbol mapping (structure adapted from remodex's
/// `RemodexIcon` table; the icon *assets* are deliberately not copied).
///
/// lint:allow namespace-type — constant symbol table. (lint:allow)
enum SupermuxHarnessToolIcon {
    static func symbol(for toolName: String) -> String {
        switch toolName {
        case "Read", "NotebookRead": return "doc.text"
        case "Write": return "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "WebSearch": return "globe"
        case "WebFetch": return "arrow.down.circle"
        case "Task", "ListAgents", "SendMessage": return "person.2"
        case "TodoWrite": return "checklist"
        case "Skill": return "wand.and.stars"
        case "ToolSearch": return "wrench.and.screwdriver"
        case "AskUserQuestion": return "questionmark.bubble"
        case "EnterPlanMode", "ExitPlanMode": return "list.bullet.rectangle"
        default:
            return toolName.hasPrefix("mcp__") ? "point.3.connected.trianglepath.dotted" : "hammer"
        }
    }
}

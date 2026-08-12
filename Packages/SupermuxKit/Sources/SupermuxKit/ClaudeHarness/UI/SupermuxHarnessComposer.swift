import AppKit
import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness

/// The composer card: input, queued-prompt chips, slash-command autocomplete,
/// and the runtime bar (model, effort, fast mode, send/stop).
///
/// `TextField(axis: .vertical)` gives auto-growth and Return-to-send through
/// `onSubmit` — but **not** Shift-Return-for-newline: on macOS both plain and
/// Shift Return invoke `onSubmit` (verified against a runtime probe). The
/// submit handler therefore checks the live Shift modifier and inserts a
/// newline instead of sending. No key interception, so IME composition stays
/// native, and ⌘↩ on the send button is a modifier-proof fallback.
struct SupermuxHarnessComposer: View {
    @Binding var text: String
    let queue: [ClaudeQueuedInput]
    let slashCommands: [String]
    let modelLabel: String
    let models: [ClaudeModelDescriptor]
    let selectedModel: String?
    let effortLevels: [String]
    let effortLevel: String?
    let supportsFastMode: Bool
    let fastMode: Bool
    let maxThinkingTokens: Int?
    let isBusy: Bool
    let canSend: Bool
    let theme: SupermuxHarnessTheme
    let onSend: () -> Void
    let onInterrupt: () -> Void
    let onCancelQueued: (UUID) -> Void
    let onSelectModel: (String) -> Void
    let onSelectEffort: (String) -> Void
    let onToggleFastMode: (Bool) -> Void
    let onSetThinkingBudget: (Int) -> Void

    @FocusState private var isInputFocused: Bool
    @State private var showsRuntimePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing6) {
            if !visibleQueue.isEmpty {
                queueChips
            }
            inputField
            if !slashSuggestions.isEmpty {
                slashSuggestionList
            }
            runtimeBar
        }
        .padding(SupermuxHarnessTokens.spacing8)
        .background(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.composerRadius, style: .continuous
            )
            .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.composerRadius, style: .continuous
            )
            .strokeBorder(
                isInputFocused ? theme.accent.opacity(0.6) : theme.border,
                lineWidth: isInputFocused ? 1 : SupermuxHarnessTokens.hairline
            )
        )
        .padding(.horizontal, SupermuxHarnessTokens.spacing12)
        .padding(.bottom, SupermuxHarnessTokens.spacing10)
    }

    // MARK: - Input

    private var inputField: some View {
        TextField(
            String(
                localized: "supermux.harness.composer.placeholder",
                defaultValue: "Message Claude Code"
            ),
            text: $text,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...12)
        .cmuxFont(size: SupermuxHarnessTokens.body)
        .foregroundStyle(theme.text)
        .focused($isInputFocused)
        .onSubmit {
            // Shift-Return inserts a newline; plain Return sends. Checked here
            // (not via key interception) so marked-text IME input is untouched.
            if NSEvent.modifierFlags.contains(.shift) {
                text.append("\n")
            } else {
                onSend()
            }
        }
    }

    // MARK: - Queue

    /// Entries the user can still act on. Acknowledged ones are history.
    private var visibleQueue: [ClaudeQueuedInput] {
        queue.filter { $0.state == .queued || $0.state == .dispatching || $0.state == .uncertain }
    }

    private var queueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SupermuxHarnessTokens.spacing4) {
                ForEach(visibleQueue) { entry in
                    SupermuxHarnessQueueChip(
                        entry: entry,
                        theme: theme,
                        onCancel: { onCancelQueued(entry.id) }
                    )
                }
            }
        }
        .frame(maxHeight: 26)
    }

    // MARK: - Slash commands

    /// Suggestions only while the whole draft is a single `/token` — mid-message
    /// slashes (paths, URLs, regexes) must not pop a menu.
    private var slashSuggestions: [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.contains(" "), !trimmed.contains("\n") else {
            return []
        }
        let prefix = String(trimmed.dropFirst()).lowercased()
        let matches = slashCommands.filter {
            prefix.isEmpty || $0.lowercased().hasPrefix(prefix)
        }
        return Array(matches.prefix(8))
    }

    private var slashSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashSuggestions, id: \.self) { command in
                Button {
                    text = "/\(command) "
                } label: {
                    HStack(spacing: SupermuxHarnessTokens.spacing4) {
                        Text("/\(command)")
                            .cmuxFont(size: SupermuxHarnessTokens.footnote, design: .monospaced)
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SupermuxHarnessTokens.spacing6)
                    .padding(.vertical, SupermuxHarnessTokens.spacing4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.fileBoxRadius, style: .continuous
            )
            .fill(theme.surfaceElevated)
        )
    }

    // MARK: - Runtime bar

    private var runtimeBar: some View {
        HStack(spacing: SupermuxHarnessTokens.spacing6) {
            Button {
                showsRuntimePopover = true
            } label: {
                HStack(spacing: SupermuxHarnessTokens.spacing4) {
                    if fastMode {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: SupermuxHarnessTokens.caption2))
                            .foregroundStyle(theme.toolAccent)
                    }
                    Text(modelLabel)
                        .cmuxFont(size: SupermuxHarnessTokens.caption)
                        .foregroundStyle(theme.softText)
                    if let effortLevel {
                        Text(effortLevel)
                            .cmuxFont(size: SupermuxHarnessTokens.caption2)
                            .foregroundStyle(theme.mutedText)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: SupermuxHarnessTokens.caption2))
                        .foregroundStyle(theme.mutedText)
                }
                .padding(.horizontal, SupermuxHarnessTokens.spacing6)
                .padding(.vertical, SupermuxHarnessTokens.spacing2)
                .background(
                    RoundedRectangle(
                        cornerRadius: SupermuxHarnessTokens.chipRadius, style: .continuous
                    )
                    .fill(theme.surface)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsRuntimePopover, arrowEdge: .top) {
                SupermuxHarnessRuntimePopover(
                    models: models,
                    selectedModel: selectedModel,
                    effortLevels: effortLevels,
                    effortLevel: effortLevel,
                    supportsFastMode: supportsFastMode,
                    fastMode: fastMode,
                    maxThinkingTokens: maxThinkingTokens,
                    theme: theme,
                    onSelectModel: onSelectModel,
                    onSelectEffort: onSelectEffort,
                    onToggleFastMode: onToggleFastMode,
                    onSetThinkingBudget: onSetThinkingBudget
                )
            }

            Spacer(minLength: SupermuxHarnessTokens.spacing4)
            sendButton
        }
    }

    private var sendButton: some View {
        Button(action: isBusy ? onInterrupt : onSend) {
            Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: SupermuxHarnessTokens.footnote, weight: .semibold))
                .foregroundStyle(theme.pageIsTransparent ? theme.text : theme.pageBackground)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isBusy ? theme.danger : theme.accent)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!isBusy && !canSend)
        .opacity((!isBusy && !canSend) ? 0.4 : 1)
        .help(
            isBusy
                ? String(
                    localized: "supermux.harness.composer.stop",
                    defaultValue: "Stop"
                )
                : String(
                    localized: "supermux.harness.composer.send",
                    defaultValue: "Send"
                )
        )
    }
}

/// One queued-prompt chip with its delivery state.
struct SupermuxHarnessQueueChip: View {
    let entry: ClaudeQueuedInput
    let theme: SupermuxHarnessTheme
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: SupermuxHarnessTokens.spacing4) {
            Image(systemName: symbol)
                .font(.system(size: SupermuxHarnessTokens.caption2))
                .foregroundStyle(color)
            Text(entry.text)
                .cmuxFont(size: SupermuxHarnessTokens.caption)
                .foregroundStyle(theme.softText)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if entry.state == .queued {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: SupermuxHarnessTokens.caption2))
                        .foregroundStyle(theme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SupermuxHarnessTokens.spacing6)
        .padding(.vertical, SupermuxHarnessTokens.spacing2)
        .background(
            Capsule(style: .continuous).fill(theme.surface)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.border, lineWidth: SupermuxHarnessTokens.hairline)
        )
        .help(helpText)
    }

    private var symbol: String {
        switch entry.state {
        case .queued: return "clock"
        case .dispatching: return "paperplane"
        case .uncertain: return "questionmark.circle"
        case .acknowledged: return "checkmark"
        case .cancelled: return "xmark"
        }
    }

    private var color: Color {
        switch entry.state {
        case .uncertain: return theme.danger
        case .dispatching: return theme.toolAccent
        default: return theme.mutedText
        }
    }

    private var helpText: String {
        switch entry.state {
        case .uncertain:
            return String(
                localized: "supermux.harness.queue.uncertain",
                defaultValue: "Claude Code exited before confirming this prompt. It was not resent."
            )
        case .dispatching:
            return String(
                localized: "supermux.harness.queue.dispatching",
                defaultValue: "Sending…"
            )
        default:
            return String(
                localized: "supermux.harness.queue.queued",
                defaultValue: "Queued"
            )
        }
    }
}

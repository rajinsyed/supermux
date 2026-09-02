import SwiftUI
import SupermuxMobileCore

/// The compact chip row under the prompt: command, model, effort, and
/// starting branch, each a small capsule menu.
extension SupermuxAgentWorktreeSheet {
    var chipRow: some View {
        HStack(spacing: 6) {
            commandChip
            modelChip
            if let descriptor = selectedModelDescriptor, descriptor.supportsEffort,
               !descriptor.supportedEffortLevels.isEmpty {
                effortChip(levels: descriptor.supportedEffortLevels, defaultLevel: descriptor.defaultEffortLevel)
            }
            baseBranchChip
            Spacer(minLength: 0)
        }
        .disabled(phase != .idle)
    }

    // MARK: Command

    private var commandChip: some View {
        Menu {
            ForEach(commands, id: \.self) { candidate in
                Button {
                    command = candidate
                } label: {
                    if candidate == command {
                        Label(candidate, systemImage: "checkmark")
                    } else {
                        Text(candidate)
                    }
                }
            }
            Divider()
            Button(String(localized: "supermux.agent.commands.edit", defaultValue: "Edit Commands…")) {
                showsCommandEditor = true
            }
        } label: {
            SupermuxAgentChipLabel(systemImage: "terminal", text: command, monospaced: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(String(
            localized: "supermux.agent.commands.help",
            defaultValue: "The shell command that starts Claude (an alias like “cc” works)."
        ))
        .popover(isPresented: $showsCommandEditor, arrowEdge: .bottom) {
            SupermuxAgentCommandEditor(commands: commands) { edited in
                saveCommands(edited)
            }
        }
    }

    // MARK: Model

    private var modelChip: some View {
        Menu {
            Button {
                selectedModel = nil
            } label: {
                if selectedModel == nil {
                    Label(defaultModelTitle, systemImage: "checkmark")
                } else {
                    Text(defaultModelTitle)
                }
            }
            if !models.isEmpty {
                Divider()
                ForEach(models) { descriptor in
                    Button {
                        selectedModel = descriptor.value
                    } label: {
                        if descriptor.value == selectedModel {
                            Label(descriptor.displayName, systemImage: "checkmark")
                        } else {
                            Text(descriptor.displayName)
                        }
                    }
                }
            }
            Divider()
            Button(String(localized: "supermux.agent.models.refresh", defaultValue: "Refresh Models")) {
                Task { await loadModels(for: command, forceRefresh: true) }
            }
            .disabled(modelsLoading)
        } label: {
            SupermuxAgentChipLabel(
                systemImage: "cpu",
                text: selectedModelDescriptor?.displayName ?? defaultModelTitle,
                isLoading: modelsLoading,
                isWarning: modelsError != nil
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(modelsError ?? String(
            localized: "supermux.agent.models.help",
            defaultValue: "Models the selected command offers."
        ))
    }

    private var defaultModelTitle: String {
        String(localized: "supermux.agent.model.default", defaultValue: "Default model")
    }

    // MARK: Effort

    private func effortChip(levels: [String], defaultLevel: String?) -> some View {
        Menu {
            Button {
                selectedEffort = nil
            } label: {
                if selectedEffort == nil {
                    Label(defaultEffortTitle(defaultLevel), systemImage: "checkmark")
                } else {
                    Text(defaultEffortTitle(defaultLevel))
                }
            }
            Divider()
            ForEach(levels, id: \.self) { level in
                Button {
                    selectedEffort = level
                } label: {
                    if level == selectedEffort {
                        Label(SupermuxAgentEffortLabel.title(for: level), systemImage: "checkmark")
                    } else {
                        Text(SupermuxAgentEffortLabel.title(for: level))
                    }
                }
            }
        } label: {
            SupermuxAgentChipLabel(
                systemImage: "gauge.with.dots.needle.67percent",
                text: selectedEffort.map(SupermuxAgentEffortLabel.title(for:))
                    ?? String(localized: "supermux.agent.effort.default", defaultValue: "Auto effort")
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(String(localized: "supermux.agent.effort.help", defaultValue: "Reasoning effort for this session."))
    }

    private func defaultEffortTitle(_ defaultLevel: String?) -> String {
        if let defaultLevel {
            let format = String(
                localized: "supermux.agent.effort.defaultNamed",
                defaultValue: "Default (%@)"
            )
            return String(format: format, SupermuxAgentEffortLabel.title(for: defaultLevel))
        }
        return String(localized: "supermux.agent.effort.default", defaultValue: "Auto effort")
    }

    // MARK: Base branch

    private var baseBranchChip: some View {
        Menu {
            Button {
                baseBranch = ""
                baseBranchWasEdited = true
            } label: {
                let head = String(localized: "supermux.newWorktree.base.default", defaultValue: "Repository HEAD")
                if baseBranch.isEmpty {
                    Label(head, systemImage: "checkmark")
                } else {
                    Text(head)
                }
            }
            if !baseBranchOptions.isEmpty {
                Divider()
                ForEach(baseBranchOptions, id: \.self) { branch in
                    Button {
                        baseBranch = branch
                        baseBranchWasEdited = true
                    } label: {
                        if branch == baseBranch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
        } label: {
            SupermuxAgentChipLabel(
                systemImage: "arrow.triangle.branch",
                text: baseBranch.isEmpty
                    ? String(localized: "supermux.agent.base.head", defaultValue: "HEAD")
                    : baseBranch,
                monospaced: true,
                isLoading: !branchesLoaded
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(String(localized: "supermux.newWorktree.base.label", defaultValue: "Start from"))
    }
}

/// Localized display names for Claude effort levels (the wire tokens are not
/// prose — `xhigh` in particular).
enum SupermuxAgentEffortLabel {
    static func title(for level: String) -> String {
        switch level.lowercased() {
        case "low": return String(localized: "supermux.agent.effort.low", defaultValue: "Low")
        case "medium": return String(localized: "supermux.agent.effort.medium", defaultValue: "Medium")
        case "high": return String(localized: "supermux.agent.effort.high", defaultValue: "High")
        case "xhigh": return String(localized: "supermux.agent.effort.xhigh", defaultValue: "Extra High")
        case "max": return String(localized: "supermux.agent.effort.max", defaultValue: "Max")
        default: return level
        }
    }
}

/// One capsule chip: icon, text, and a chevron; optionally a spinner or a
/// warning tint when the backing data could not be read.
struct SupermuxAgentChipLabel: View {
    let systemImage: String
    let text: String
    var monospaced = false
    var isLoading = false
    var isWarning = false

    var body: some View {
        HStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: isWarning ? "exclamationmark.triangle" : systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// Popover editor for the Claude command list: one command per line.
struct SupermuxAgentCommandEditor: View {
    @State private var text: String
    private let save: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(commands: [String], save: @escaping ([String]) -> Void) {
        _text = State(initialValue: commands.joined(separator: "\n"))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "supermux.agent.commands.title", defaultValue: "Claude Commands"))
                .font(.system(size: 12, weight: .semibold))
            Text(String(
                localized: "supermux.agent.commands.hint",
                defaultValue: "One per line. Aliases and wrapper scripts from your shell work (claude, cc, ccx…)."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 240, height: 84)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "supermux.common.save", defaultValue: "Save")) {
                    save(text.split(whereSeparator: \.isNewline).map(String.init))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

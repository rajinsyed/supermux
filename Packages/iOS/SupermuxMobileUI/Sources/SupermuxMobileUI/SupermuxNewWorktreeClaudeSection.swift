import SupermuxMobileKit
import SwiftUI

/// The Claude section of the New Worktree sheet: command, model, and effort
/// pickers fed by the Mac's launch options, plus the resolved command line.
struct SupermuxNewWorktreeClaudeSection: View {
    let store: SupermuxMobileAgentLaunchStore
    let isBusy: Bool

    var body: some View {
        Section {
            if store.commands.count > 1 {
                Picker(
                    String(localized: "supermux.agent.command.label", defaultValue: "Command", bundle: .module),
                    selection: Binding(
                        get: { store.command },
                        set: { newValue in Task { await store.selectCommand(newValue) } }
                    )
                ) {
                    ForEach(store.commands, id: \.self) { command in
                        Text(command).monospaced().tag(command)
                    }
                }
                .disabled(isBusy || store.isLoadingOptions)
            }
            modelRow
            if !store.effortLevels.isEmpty {
                Picker(
                    String(localized: "supermux.agent.effort.label", defaultValue: "Effort", bundle: .module),
                    selection: Binding(
                        get: { store.selectedEffort ?? "" },
                        set: { store.selectedEffort = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text(defaultEffortTitle).tag("")
                    ForEach(store.effortLevels, id: \.self) { level in
                        Text(SupermuxAgentEffortLabel.title(for: level)).tag(level)
                    }
                }
                .disabled(isBusy)
            }
        } header: {
            Text(String(localized: "supermux.agent.section.claude", defaultValue: "Claude", bundle: .module))
        } footer: {
            if let modelsError = store.modelsError {
                Label(modelsError, systemImage: "exclamationmark.triangle")
            } else {
                Text(commandPreview)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if store.isLoadingOptions, store.models.isEmpty {
            HStack {
                Text(String(localized: "supermux.agent.model.label", defaultValue: "Model", bundle: .module))
                Spacer()
                ProgressView()
            }
        } else {
            Picker(
                String(localized: "supermux.agent.model.label", defaultValue: "Model", bundle: .module),
                selection: Binding(
                    get: { store.selectedModel ?? "" },
                    set: { store.selectedModel = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text(store.defaultModelEntry?.displayName
                    ?? String(localized: "supermux.agent.model.default", defaultValue: "Default", bundle: .module))
                    .tag("")
                ForEach(store.selectableModels) { model in
                    Text(model.displayName).tag(model.value)
                }
            }
            .disabled(isBusy)
        }
    }

    private var defaultEffortTitle: String {
        if let level = store.selectedModelDescriptor?.defaultEffortLevel {
            let format = String(localized: "supermux.agent.effort.defaultNamed", defaultValue: "Default (%@)", bundle: .module)
            return String(format: format, SupermuxAgentEffortLabel.title(for: level))
        }
        return String(localized: "supermux.agent.effort.default", defaultValue: "Default", bundle: .module)
    }

    /// `<command> [--model M] [--effort E] …`, so the pickers are never a guess.
    private var commandPreview: String {
        var parts = [store.command]
        if let model = store.selectedModel { parts += ["--model", model] }
        if let effort = store.selectedEffort { parts += ["--effort", effort] }
        parts.append("\"…\"")
        return parts.joined(separator: " ")
    }
}

/// Localized display names for Claude effort levels on the phone.
enum SupermuxAgentEffortLabel {
    static func title(for level: String) -> String {
        switch level.lowercased() {
        case "low": return String(localized: "supermux.agent.effort.low", defaultValue: "Low", bundle: .module)
        case "medium": return String(localized: "supermux.agent.effort.medium", defaultValue: "Medium", bundle: .module)
        case "high": return String(localized: "supermux.agent.effort.high", defaultValue: "High", bundle: .module)
        case "xhigh": return String(localized: "supermux.agent.effort.xhigh", defaultValue: "Extra High", bundle: .module)
        case "max": return String(localized: "supermux.agent.effort.max", defaultValue: "Max", bundle: .module)
        default: return level
        }
    }
}

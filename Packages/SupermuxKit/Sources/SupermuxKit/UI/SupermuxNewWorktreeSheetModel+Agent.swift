public import Foundation
public import SupermuxMobileCore

/// The Claude chips' state: the selected Mac's commands, the chosen command's
/// model catalog, and the remembered model / effort.
extension SupermuxNewWorktreeSheetModel {
    /// The effort levels the current model selection accepts.
    public var effortLevels: [String] { models.effortLevels(forSelection: selectedModel) }

    /// The catalog entry of the selected model, if any.
    public var selectedModelDescriptor: SupermuxAgentModelDTO? {
        guard let selectedModel else { return nil }
        return models.first { $0.value == selectedModel }
    }

    /// Whether the command list can be edited here (this Mac only).
    public var canEditCommands: Bool { target?.canEditAgentCommands == true }

    /// The exact shell line the new terminal will run; `nil` when another
    /// Mac's shell builds it.
    public var previewLine: String? {
        target?.shellLinePreview(command: command, model: selectedModel, effort: selectedEffort, prompt: prompt)
    }

    /// Drops an effort the newly chosen model does not accept.
    public func clampEffort() {
        guard let effort = selectedEffort, !effortLevels.contains(effort) else { return }
        selectedEffort = nil
    }

    /// Switches the Claude command: remembers it, drops the previous command's
    /// catalog and picks synchronously (a Start pressed while the new catalog
    /// probes then launches on the CLI default instead of a model the new
    /// command may not accept), and loads the new catalog.
    public func selectCommand(_ newCommand: String) {
        guard newCommand != command else { return }
        command = newCommand
        target?.rememberAgentCommand(newCommand)
        models = []
        modelsError = nil
        selectedModel = nil
        selectedEffort = nil
        Task { await loadModels(for: newCommand) }
    }

    /// Replaces the command list from the editor popover.
    public func saveCommands(_ edited: [String]) {
        guard let target, target.canEditAgentCommands else { return }
        let list = target.setAgentCommands(edited)
        commands = list.commands
        if !commands.contains(command) {
            selectCommand(list.selected)
        }
    }

    /// Loads `command`'s catalog. The first load for a command applies the
    /// remembered model/effort; a refresh (`forceRefresh`) or a reload of a
    /// catalog already shown (the Mac reconnected) keeps the user's current
    /// picks, dropping only a model the new catalog no longer lists.
    /// Another Mac's command list is not known up front: the first load adopts
    /// the list and selection that Mac answers with.
    public func loadModels(for command: String, forceRefresh: Bool = false) async {
        guard let target, target.supportsAgentLaunch else { return }
        let adoptsCommandList = commands.isEmpty
        guard adoptsCommandList || !command.isEmpty else { return }
        let keepsPicks = forceRefresh || !models.isEmpty
        let generation = targetGeneration
        modelsLoading = true
        modelsError = nil
        defer { if generation == targetGeneration { modelsLoading = false } }
        let options = await target.agentOptions(for: command, forceRefresh: forceRefresh)
        guard generation == targetGeneration else { return }
        if adoptsCommandList {
            // A concurrent load may have adopted the list already.
            guard commands.isEmpty else { return }
            commands = options.commands
            self.command = options.selectedCommand
        } else if command != self.command {
            // The user switched commands while this probe ran.
            return
        }
        models = options.models
        modelsError = options.modelsSource == .unavailable ? options.modelsError : nil
        if keepsPicks {
            if let selectedModel, !models.selectableModels.contains(where: { $0.value == selectedModel }) {
                self.selectedModel = nil
            }
        } else {
            if let lastModel = options.lastModel, models.selectableModels.contains(where: { $0.value == lastModel }) {
                selectedModel = lastModel
            } else {
                selectedModel = nil
            }
            selectedEffort = options.lastEffort
        }
        clampEffort()
    }
}

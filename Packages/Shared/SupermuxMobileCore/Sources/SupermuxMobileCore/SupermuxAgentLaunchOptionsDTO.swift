/// `mobile.supermux.agent.options` result: everything the phone's "Start
/// Claude in a new worktree" sheet needs to render its pickers.
///
/// The Mac owns the list of Claude commands (`claude`, `cc`, `ccx`, …) and
/// probes each one for its model catalog; the phone only picks. ``models``
/// describes the ``selectedCommand``'s catalog — switching commands means a
/// fresh request with that command.
public struct SupermuxAgentLaunchOptionsDTO: Codable, Sendable, Equatable {
    /// Where ``models`` came from, so the phone can hint at staleness.
    public enum ModelsSource: String, Codable, Sendable, Equatable {
        /// A persisted catalog from an earlier probe.
        case cache
        /// A fresh probe of the command completed for this request.
        case probe
        /// No catalog could be read; ``models`` is empty and the CLI default
        /// applies.
        case unavailable
    }

    /// The Claude commands the Mac user configured, in display order.
    public var commands: [String]
    /// The command the options describe (the caller's request, else the
    /// Mac's remembered selection).
    public var selectedCommand: String
    /// The selected command's model catalog (may be empty).
    public var models: [SupermuxAgentModelDTO]
    /// Where ``models`` came from.
    public var modelsSource: ModelsSource
    /// A user-facing reason when ``modelsSource`` is `unavailable`.
    public var modelsError: String?
    /// The model last used with the selected command, when recorded.
    public var lastModel: String?
    /// The effort last used with the selected command, when recorded.
    public var lastEffort: String?

    /// Creates the options payload.
    public init(
        commands: [String],
        selectedCommand: String,
        models: [SupermuxAgentModelDTO],
        modelsSource: ModelsSource,
        modelsError: String? = nil,
        lastModel: String? = nil,
        lastEffort: String? = nil
    ) {
        self.commands = commands
        self.selectedCommand = selectedCommand
        self.models = models
        self.modelsSource = modelsSource
        self.modelsError = modelsError
        self.lastModel = lastModel
        self.lastEffort = lastEffort
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commands = (try container.decodeIfPresent([String].self, forKey: .commands)) ?? []
        selectedCommand = (try container.decodeIfPresent(String.self, forKey: .selectedCommand))
            ?? commands.first ?? ""
        models = (try container.decodeIfPresent([SupermuxAgentModelDTO].self, forKey: .models)) ?? []
        modelsSource = (try? container.decode(ModelsSource.self, forKey: .modelsSource)) ?? .unavailable
        modelsError = try container.decodeIfPresent(String.self, forKey: .modelsError)
        lastModel = try container.decodeIfPresent(String.self, forKey: .lastModel)
        lastEffort = try container.decodeIfPresent(String.self, forKey: .lastEffort)
    }

    private enum CodingKeys: String, CodingKey {
        case commands
        case selectedCommand = "selected_command"
        case models
        case modelsSource = "models_source"
        case modelsError = "models_error"
        case lastModel = "last_model"
        case lastEffort = "last_effort"
    }
}

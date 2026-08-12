/// Mac-advertised creation and mutation options for Claude harness sessions.
public struct SupermuxClaudeOptionsDTO: Codable, Sendable, Equatable {
    /// Available model choices.
    public var models: [SupermuxClaudeModelOptionDTO]
    /// Effort values supported by at least one available model.
    public var supportedEffortLevels: [String]
    /// Whether any available configuration supports fast mode.
    public var supportsFastMode: Bool
    /// Slash commands reported by the harness initialization handshake.
    public var slashCommands: [String]
    /// Availability of Mac-side launchers.
    public var launchers: [SupermuxClaudeLauncherAvailabilityDTO]

    /// Creates an options snapshot.
    /// - Parameters:
    ///   - models: Available model choices.
    ///   - supportedEffortLevels: Advertised effort values.
    ///   - supportsFastMode: Whether fast mode is supported.
    ///   - slashCommands: Harness-reported slash commands.
    ///   - launchers: Mac-side launcher availability.
    public init(
        models: [SupermuxClaudeModelOptionDTO],
        supportedEffortLevels: [String],
        supportsFastMode: Bool,
        slashCommands: [String],
        launchers: [SupermuxClaudeLauncherAvailabilityDTO]
    ) {
        self.models = models
        self.supportedEffortLevels = supportedEffortLevels
        self.supportsFastMode = supportsFastMode
        self.slashCommands = slashCommands
        self.launchers = launchers
    }

    private enum CodingKeys: String, CodingKey {
        case models
        case supportedEffortLevels = "supported_effort_levels"
        case supportsFastMode = "supports_fast_mode"
        case slashCommands = "slash_commands"
        case launchers
    }
}

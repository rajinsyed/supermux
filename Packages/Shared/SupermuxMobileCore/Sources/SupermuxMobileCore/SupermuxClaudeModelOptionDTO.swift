/// One model advertised by `mobile.supermux.claude.options`.
public struct SupermuxClaudeModelOptionDTO: Codable, Sendable, Equatable {
    /// Value accepted by Claude Code's model option.
    public var value: String
    /// Fully resolved model identifier, when reported.
    public var resolvedModel: String?
    /// User-facing model name.
    public var displayName: String?
    /// Bounded user-facing model description.
    public var description: String?
    /// Effort levels supported by this model.
    public var supportedEffortLevels: [String]
    /// Whether this model supports fast mode.
    public var supportsFastMode: Bool

    /// Creates a mobile model option.
    /// - Parameters:
    ///   - value: Value accepted by Claude Code.
    ///   - resolvedModel: Fully resolved model identifier.
    ///   - displayName: User-facing model name.
    ///   - description: Bounded model description.
    ///   - supportedEffortLevels: Supported effort values.
    ///   - supportsFastMode: Whether fast mode is supported.
    public init(
        value: String,
        resolvedModel: String? = nil,
        displayName: String? = nil,
        description: String? = nil,
        supportedEffortLevels: [String] = [],
        supportsFastMode: Bool = false
    ) {
        self.value = value
        self.resolvedModel = resolvedModel
        self.displayName = displayName
        self.description = description
        self.supportedEffortLevels = supportedEffortLevels
        self.supportsFastMode = supportsFastMode
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case resolvedModel = "resolved_model"
        case displayName = "display_name"
        case description
        case supportedEffortLevels = "supported_effort_levels"
        case supportsFastMode = "supports_fast_mode"
    }
}

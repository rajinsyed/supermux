/// Wire representation of one model a Claude Code executable advertises.
///
/// Mirrors the model objects Claude Code returns from its `initialize` control
/// response (`value`, `displayName`, `supportsEffort`, …), normalized into a
/// stable snake_case shape so the phone can render the same picker the Mac
/// shows. Only ``value`` is required; a wrapper binary that exposes a
/// different provider's models (e.g. a proxy) still fits.
public struct SupermuxAgentModelDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The selector passed to `--model` (e.g. `claude-opus-5`, `opus[1m]`).
    public var value: String
    /// Human-readable name; falls back to ``value`` when the CLI sent none.
    public var displayName: String
    /// Optional one-line description from the CLI.
    public var description: String?
    /// Whether the model accepts `--effort`.
    public var supportsEffort: Bool
    /// The ordered effort levels the model accepts, when it supports effort.
    public var supportedEffortLevels: [String]
    /// The level the CLI uses when none is passed, when advertised.
    public var defaultEffortLevel: String?

    /// `Identifiable` conformance — models are unique by selector.
    public var id: String { value }

    /// Creates a model DTO.
    /// - Parameters:
    ///   - value: The `--model` selector.
    ///   - displayName: Human-readable name (defaults to `value`).
    ///   - description: Optional description.
    ///   - supportsEffort: Whether `--effort` applies.
    ///   - supportedEffortLevels: Ordered accepted effort levels.
    ///   - defaultEffortLevel: The CLI's default level, when known.
    public init(
        value: String,
        displayName: String? = nil,
        description: String? = nil,
        supportsEffort: Bool = false,
        supportedEffortLevels: [String] = [],
        defaultEffortLevel: String? = nil
    ) {
        self.value = value
        self.displayName = displayName ?? value
        self.description = description
        self.supportsEffort = supportsEffort
        self.supportedEffortLevels = supportedEffortLevels
        self.defaultEffortLevel = defaultEffortLevel
    }

    /// Builds a DTO from one raw `initialize` model object.
    ///
    /// Tolerant on purpose: Claude Code has spelled these fields several ways
    /// across versions, so both camelCase and snake_case keys are accepted and
    /// anything unrecognized is ignored. Returns `nil` only when no selector
    /// can be found.
    /// - Parameter initializeModel: The raw JSON object from the CLI.
    public init?(initializeModel object: [String: Any]) {
        guard let value = Self.string(object, "value") ?? Self.string(object, "id"),
              !value.isEmpty else {
            return nil
        }
        let levels = (object["supportedEffortLevels"] ?? object["supported_effort_levels"]) as? [Any]
        let parsedLevels = (levels ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        let supportsEffort = ((object["supportsEffort"] ?? object["supports_effort"]) as? Bool)
            ?? !parsedLevels.isEmpty
        self.init(
            value: value,
            displayName: Self.string(object, "displayName") ?? Self.string(object, "display_name"),
            description: Self.string(object, "description"),
            supportsEffort: supportsEffort,
            supportedEffortLevels: parsedLevels,
            defaultEffortLevel: Self.string(object, "defaultEffortLevel")
                ?? Self.string(object, "default_effort_level")
        )
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let raw = object[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        self.value = value
        displayName = (try container.decodeIfPresent(String.self, forKey: .displayName)) ?? value
        description = try container.decodeIfPresent(String.self, forKey: .description)
        supportsEffort = (try container.decodeIfPresent(Bool.self, forKey: .supportsEffort)) ?? false
        supportedEffortLevels = (try container.decodeIfPresent([String].self, forKey: .supportedEffortLevels)) ?? []
        defaultEffortLevel = try container.decodeIfPresent(String.self, forKey: .defaultEffortLevel)
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case displayName = "display_name"
        case description
        case supportsEffort = "supports_effort"
        case supportedEffortLevels = "supported_effort_levels"
        case defaultEffortLevel = "default_effort_level"
    }
}

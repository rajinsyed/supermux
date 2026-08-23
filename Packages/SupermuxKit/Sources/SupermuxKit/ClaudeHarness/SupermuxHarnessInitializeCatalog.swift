import Foundation

/// Account-specific capabilities extracted from Claude Code's initialize control response.
public struct SupermuxHarnessInitializeCatalog: Equatable, Sendable {
    /// Models available to the signed-in Claude account.
    public let models: [SupermuxHarnessJSONObject]
    /// Named built-in and configured agents.
    public let agents: [String]
    /// Named output styles available to the account.
    public let availableOutputStyles: [String]
    /// Slash-command names advertised by the CLI.
    public let commandNames: [String]

    /// Extracts the tolerant catalog fields from an initialize response.
    ///
    /// String and object forms are both accepted for agents and output styles because Claude Code
    /// has emitted both shapes across versions. Entries without a usable name are ignored.
    ///
    /// - Parameter response: The nested success payload from the initialize control response.
    public init(response: SupermuxHarnessJSONObject) {
        models = response.objects(forKey: "models") ?? []
        agents = Self.names(in: response["agents"], objectKeys: ["name"])
        availableOutputStyles = Self.names(
            in: response["available_output_styles"],
            objectKeys: ["name", "value"]
        )
        commandNames = Self.names(in: response["commands"], objectKeys: ["name"])
    }

    private static func names(in value: Any?, objectKeys: [String]) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { entry in
            if let string = normalized(entry as? String) {
                return string
            }
            guard let object = entry as? [String: Any] else { return nil }
            return objectKeys.lazy.compactMap { normalized(object[$0] as? String) }.first
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

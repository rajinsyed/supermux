import Foundation

/// Saves a project's run/setup/teardown/actions into its fork-native
/// `.supermux/config.json`.
public struct SupermuxProjectConfigWriter: Sendable {
    /// Where Supermux writes a project's config, relative to the project root.
    public static let relativePath = ".supermux/config.json"

    public init() {}

    /// Writes `config` to `<projectRoot>/.supermux/config.json`.
    public func write(_ config: SupermuxProjectConfig, projectRoot: String) throws {}
}

public extension SupermuxProjectConfig {
    /// The config-managed fields of `project`.
    init(project: SupermuxProject) {
        self.init()
    }
}

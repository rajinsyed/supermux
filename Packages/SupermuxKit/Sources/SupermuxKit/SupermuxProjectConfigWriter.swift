import Foundation

/// Saves a project's run/setup/teardown/actions into its fork-native
/// `.supermux/config.json`.
///
/// ``SupermuxProjectConfigLoader`` reads `.supermux/config.json` before
/// superset's `.superset/config.json`, so once written this file owns all four
/// fields and superset's file is never touched. All four keys are always
/// written, even when empty, so a field cleared in the editor stays cleared
/// instead of falling back to superset's value.
///
/// Pure value type with a synchronous `write` so callers run it off the main
/// actor (e.g. `Task.detached`).
public struct SupermuxProjectConfigWriter: Sendable {
    /// Where Supermux writes a project's config, relative to the project root.
    public static let relativePath = ".supermux/config.json"

    /// Why a save was refused.
    public enum WriteError: Error, Equatable {
        /// The project root does not exist (moved or deleted).
        case projectRootMissing(String)
        /// The existing `.supermux/config.json` is not a config the loader
        /// can read (bad JSON, or the wrong shape); it is left as is rather
        /// than replaced.
        case existingFileUnreadable(String)
    }

    public init() {}

    /// Writes `config` to `<projectRoot>/.supermux/config.json`, keeping any
    /// other top-level keys an existing file already has.
    /// - Parameters:
    ///   - config: The run/setup/teardown/actions to save.
    ///   - projectRoot: Absolute project root path.
    /// - Throws: ``WriteError`` when the root is missing or the existing file
    ///   is not a JSON object, or the underlying file error.
    public func write(_ config: SupermuxProjectConfig, projectRoot: String) throws {
        let root = (projectRoot as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WriteError.projectRootMissing(root)
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent(Self.relativePath)
        var object = try existingObject(at: url)
        object["setup"] = config.setup
        object["teardown"] = config.teardown
        object["run"] = config.run
        object["actions"] = config.actions.map(Self.jsonObject)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// The file's current top-level object, or an empty one when the file
    /// does not exist yet. A file the loader skips is refused: the editor
    /// then shows another file's values, and saving them here would replace
    /// what the user wrote.
    private func existingObject(at url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [:] }
        guard (try? JSONDecoder().decode(SupermuxProjectConfig.self, from: data)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WriteError.existingFileUnreadable(url.path)
        }
        return object
    }

    private static func jsonObject(_ action: SupermuxProjectConfig.Action) -> [String: Any] {
        var object: [String: Any] = ["name": action.name, "command": action.command]
        if let id = action.id { object["id"] = id }
        if let icon = action.icon { object["icon"] = icon }
        return object
    }
}

public extension SupermuxProjectConfig {
    /// The config-managed fields of `project`, shaped so that re-importing
    /// them with ``SupermuxProject/applying(_:)`` gives the same values back.
    /// - Parameter project: The project whose run/setup/teardown/actions to copy.
    init(project: SupermuxProject) {
        self.init(
            setup: project.setupCommands,
            teardown: project.teardownCommands,
            run: project.runCommands,
            actions: project.actions.map(Action.init(action:))
        )
    }
}

public extension SupermuxProjectConfig.Action {
    /// The config form of a project action, keeping its id and icon.
    /// - Parameter action: The project action to copy.
    init(action: SupermuxProjectAction) {
        self.init(
            id: action.id.uuidString,
            name: action.name,
            command: action.command,
            icon: action.iconSymbol
        )
    }
}

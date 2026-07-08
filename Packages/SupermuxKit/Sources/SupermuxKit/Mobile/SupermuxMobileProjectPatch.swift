public import Foundation
internal import SupermuxMobileCore

/// The parsed `patch` object of `mobile.supermux.project.update`.
///
/// Patch semantics (validation contract RPC-PROJ-02): only keys present in
/// the wire object are applied; array-valued fields (`run_commands`,
/// `setup_commands`, `teardown_commands`, `actions`) are replaced whole,
/// never merged. Nullable fields (`color_hex`, `icon_symbol`,
/// `default_branch`) are cleared by an explicit `null`. Immutable and
/// unknown keys are rejected at parse time, and config-managed fields are
/// rejected at apply time when a repo-shipped `config.json` owns them —
/// the same fields the desktop editor renders read-only.
public struct SupermuxMobileProjectPatch: Sendable {
    /// New display name (present ⇒ non-empty).
    public var name: String?
    /// Accent color; `.some(nil)` clears it.
    public var colorHex: String??
    /// SF Symbol avatar; `.some(nil)` clears it (letter avatar).
    public var iconSymbol: String??
    /// Base branch for new worktrees; `.some(nil)` clears it (uses `HEAD`).
    public var defaultBranch: String??
    /// Worktree container directory name (single path component).
    public var worktreesDirName: String?
    /// Run-action commands, replaced whole.
    public var runCommands: [String]?
    /// Fresh-worktree setup commands, replaced whole.
    public var setupCommands: [String]?
    /// Pre-removal teardown commands, replaced whole.
    public var teardownCommands: [String]?
    /// Named custom actions, replaced whole.
    public var actions: [SupermuxProjectAction]?

    /// Server-owned fields a patch may never name.
    static let immutableKeys: Set<String> = [
        "id", "root_path", "created_at", "last_opened_at",
        "has_custom_icon", "custom_icon_path", "config_path",
    ]

    /// Parses the wire patch object, rejecting immutable, unknown, and
    /// malformed keys with the ``SupermuxMobilePatchError`` that maps to
    /// `invalid_params`.
    /// - Parameter wire: The request's `patch` object.
    public init(wire: [String: Any]) throws {
        let allowedKeys: Set<String> = [
            "name", "color_hex", "icon_symbol", "default_branch",
            "worktrees_dir_name", "run_commands", "setup_commands",
            "teardown_commands", "actions",
        ]
        for key in wire.keys where !allowedKeys.contains(key) {
            if Self.immutableKeys.contains(key) {
                throw SupermuxMobilePatchError.immutableKey(key)
            }
            throw SupermuxMobilePatchError.unknownKey(key)
        }
        name = try SupermuxMobileWireValue.string(wire, key: "name")
        colorHex = try SupermuxMobileWireValue.nullableString(wire, key: "color_hex")
        iconSymbol = try SupermuxMobileWireValue.nullableString(wire, key: "icon_symbol")
        defaultBranch = try SupermuxMobileWireValue.nullableString(wire, key: "default_branch")
        worktreesDirName = try Self.worktreesDirName(from: wire)
        runCommands = try SupermuxMobileWireValue.stringArray(wire, key: "run_commands")
        setupCommands = try SupermuxMobileWireValue.stringArray(wire, key: "setup_commands")
        teardownCommands = try SupermuxMobileWireValue.stringArray(wire, key: "teardown_commands")
        actions = try Self.actions(from: wire)
    }

    /// Applies the patch: present keys only, arrays whole.
    ///
    /// - Parameters:
    ///   - project: The current project record.
    ///   - isConfigManaged: Whether a repo-shipped `config.json` owns the
    ///     run/setup/teardown/actions fields (see
    ///     ``SupermuxMobileProjectConfigMarker``). Patching them then throws
    ///     ``SupermuxMobilePatchError/configManagedKey(_:)`` — the desktop
    ///     editor disables those fields for the same reason, and any accepted
    ///     edit would be silently overwritten by the next config re-import.
    /// - Returns: The patched record (same `id`, `rootPath`, timestamps).
    public func applied(to project: SupermuxProject, isConfigManaged: Bool) throws -> SupermuxProject {
        if isConfigManaged {
            let configManaged: [(String, Bool)] = [
                ("run_commands", runCommands != nil),
                ("setup_commands", setupCommands != nil),
                ("teardown_commands", teardownCommands != nil),
                ("actions", actions != nil),
            ]
            if let (key, _) = configManaged.first(where: { $0.1 }) {
                throw SupermuxMobilePatchError.configManagedKey(key)
            }
        }
        var copy = project
        if let name { copy.name = name }
        if let colorHex { copy.colorHex = colorHex }
        if let iconSymbol { copy.iconSymbol = iconSymbol }
        if let defaultBranch { copy.defaultBranch = defaultBranch }
        if let worktreesDirName { copy.worktreesDirName = worktreesDirName }
        if let runCommands { copy.runCommands = runCommands }
        if let setupCommands { copy.setupCommands = setupCommands }
        if let teardownCommands { copy.teardownCommands = teardownCommands }
        if let actions { copy.actions = actions }
        return copy
    }

    /// `worktrees_dir_name` must stay a single, real directory name — it is
    /// appended to the project root to form the worktree container path.
    private static func worktreesDirName(from wire: [String: Any]) throws -> String? {
        guard let value = try SupermuxMobileWireValue.string(wire, key: "worktrees_dir_name") else {
            return nil
        }
        guard !value.contains("/"), value != ".", value != ".." else {
            throw SupermuxMobilePatchError.invalidValue(key: "worktrees_dir_name")
        }
        return value
    }

    /// Decodes `actions` as an array of ``SupermuxProjectActionDTO`` objects
    /// and maps each onto the Mac model (whole-array replacement).
    private static func actions(from wire: [String: Any]) throws -> [SupermuxProjectAction]? {
        guard let value = wire["actions"] else { return nil }
        guard let array = value as? [[String: Any]] else {
            throw SupermuxMobilePatchError.invalidValue(key: "actions")
        }
        let bridge = SupermuxWireJSON()
        return try array.map { element in
            guard let dto = try? bridge.decode(SupermuxProjectActionDTO.self, from: element),
                  let action = SupermuxProjectAction(dto: dto) else {
                throw SupermuxMobilePatchError.invalidValue(key: "actions")
            }
            return action
        }
    }
}

/// Detects the read-only marker for config-managed projects, mirroring the
/// desktop editor's rule exactly: a project is config-managed only when a
/// candidate config file exists AND parses (a malformed file leaves the
/// fields editable, matching ``SupermuxProjectsModel``'s import behavior).
///
/// Performs file I/O — call off the main actor (e.g. `Task.detached`).
public enum SupermuxMobileProjectConfigMarker {
    /// The managing config's path relative to the project root
    /// (e.g. `".supermux/config.json"`), or `nil` when the project's
    /// run/setup/teardown/actions fields are user-owned.
    /// - Parameter projectRoot: Absolute project root path.
    public static func managedRelativePath(projectRoot: String) -> String? {
        let loader = SupermuxProjectConfigLoader()
        guard loader.load(projectRoot: projectRoot) != nil else { return nil }
        return loader.resolvedRelativePath(projectRoot: projectRoot)
    }
}

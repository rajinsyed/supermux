public import Foundation
public import SupermuxMobileCore

/// The typed `patch` object of `mobile.supermux.project.update`, phone side.
///
/// Mirrors the Mac's committed patch shape (m2-f3) exactly: only present
/// keys are applied, array-valued fields (`run_commands`, `setup_commands`,
/// `teardown_commands`, `actions`) are replaced whole, and nullable fields
/// (`color_hex`, `icon_symbol`, `default_branch`) are cleared by an explicit
/// `null`. Immutable fields (`id`, `root_path`, timestamps, icon/config
/// markers) have no properties here, so the phone can never name them.
public struct SupermuxProjectPatch: Equatable, Sendable {
    /// New display name (send non-empty only; the Mac rejects blank).
    public var name: String?
    /// Accent color `#RRGGBB`; `.clear` removes it (neutral default).
    public var colorHex: SupermuxPatchField<String>?
    /// SF Symbol avatar; `.clear` removes it (letter avatar).
    public var iconSymbol: SupermuxPatchField<String>?
    /// Base branch for new worktrees; `.clear` falls back to `HEAD`.
    public var defaultBranch: SupermuxPatchField<String>?
    /// Worktree container directory name (single path component).
    public var worktreesDirName: String?
    /// Run-action commands, replaced whole.
    public var runCommands: [String]?
    /// Fresh-worktree setup commands, replaced whole.
    public var setupCommands: [String]?
    /// Pre-removal teardown commands, replaced whole.
    public var teardownCommands: [String]?
    /// Named custom actions, replaced whole.
    public var actions: [SupermuxProjectActionDTO]?

    /// Creates an empty patch; set only the fields the user changed.
    public init() {}

    /// Whether the patch names no keys at all (nothing to send).
    public var isEmpty: Bool {
        name == nil && colorHex == nil && iconSymbol == nil
            && defaultBranch == nil && worktreesDirName == nil
            && runCommands == nil && setupCommands == nil
            && teardownCommands == nil && actions == nil
    }

    /// The exact wire `patch` object: present keys only, `NSNull` for
    /// explicit clears, actions as their DTO JSON objects.
    public var wireObject: [String: Any] {
        var object: [String: Any] = [:]
        if let name { object["name"] = name }
        if let colorHex { object["color_hex"] = colorHex.wireValue }
        if let iconSymbol { object["icon_symbol"] = iconSymbol.wireValue }
        if let defaultBranch { object["default_branch"] = defaultBranch.wireValue }
        if let worktreesDirName { object["worktrees_dir_name"] = worktreesDirName }
        if let runCommands { object["run_commands"] = runCommands }
        if let setupCommands { object["setup_commands"] = setupCommands }
        if let teardownCommands { object["teardown_commands"] = teardownCommands }
        if let actions { object["actions"] = actions.map(Self.wireAction(_:)) }
        return object
    }

    /// One action's wire object, with the same key set as
    /// ``SupermuxProjectActionDTO``'s coding keys (absent optionals omitted,
    /// `kind`/`url` preserved as fetched).
    private static func wireAction(_ action: SupermuxProjectActionDTO) -> [String: Any] {
        var object: [String: Any] = [
            "id": action.id,
            "name": action.name,
            "command": action.command,
        ]
        if let iconSymbol = action.iconSymbol { object["icon_symbol"] = iconSymbol }
        if let kind = action.kind { object["kind"] = kind }
        if let url = action.url { object["url"] = url }
        return object
    }
}

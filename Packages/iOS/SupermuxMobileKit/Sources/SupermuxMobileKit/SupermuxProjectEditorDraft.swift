public import Foundation
public import SupermuxMobileCore

/// The project editor sheet's editable state, plus the diff that turns it
/// into a ``SupermuxProjectPatch``.
///
/// Seeded from a ``SupermuxProjectDTO`` and bound to the sheet's fields; on
/// save, ``patch(from:)`` emits ONLY the keys whose normalized value differs
/// from the original (present-key semantics), with the desktop editor's
/// normalization: trimmed name, per-line run commands, single-multiline-entry
/// scripts, a sanitized single-component worktrees folder, and
/// launchable-only trimmed actions. Fields owned by a repo-shipped
/// `config.json` (``SupermuxProjectDTO/configPath`` non-nil) never reach the
/// patch — they are read-only on the phone exactly as on the desktop.
public struct SupermuxProjectEditorDraft: Equatable, Sendable {
    /// The default worktree container directory name, matching the Mac model.
    public static let defaultWorktreesDirName = ".worktrees"

    /// Display name.
    public var name: String
    /// Accent color `#RRGGBB`, or `nil` for none.
    public var colorHex: String?
    /// SF Symbol avatar, or `nil` for the letter avatar.
    public var iconSymbol: String?
    /// Default base branch editor text (blank = use `HEAD`).
    public var defaultBranch: String
    /// Worktree container directory name editor text.
    public var worktreesDirName: String
    /// Run commands editor text, one command per line.
    public var runCommandsText: String
    /// Setup script editor text (stored as ONE multi-line entry).
    public var setupScriptText: String
    /// Teardown script editor text (stored as ONE multi-line entry).
    public var teardownScriptText: String
    /// Custom actions being edited (blank rows are dropped on save).
    public var actions: [SupermuxProjectActionDTO]
    /// Whether a repo-shipped `config.json` owns the run/setup/teardown/
    /// actions fields (they render disabled and are never patched).
    public let isConfigManaged: Bool

    /// Seeds the draft from a fetched project.
    /// - Parameter project: The project as the Mac last reported it.
    public init(project: SupermuxProjectDTO) {
        name = project.name
        colorHex = project.colorHex
        iconSymbol = project.iconSymbol
        defaultBranch = project.defaultBranch ?? ""
        worktreesDirName = project.worktreesDirName ?? Self.defaultWorktreesDirName
        runCommandsText = (project.runCommands ?? []).joined(separator: "\n")
        setupScriptText = (project.setupCommands ?? []).joined(separator: "\n")
        teardownScriptText = (project.teardownCommands ?? []).joined(separator: "\n")
        actions = project.actions ?? []
        isConfigManaged = project.configPath != nil
    }

    /// A blank action row with a fresh Mac-compatible UUID identity (the Mac
    /// rejects non-UUID action ids).
    public static func newAction() -> SupermuxProjectActionDTO {
        SupermuxProjectActionDTO(id: UUID().uuidString, name: "", command: "")
    }

    /// The present-key diff against the original record.
    /// - Parameter original: The project the draft was seeded from.
    /// - Returns: A patch naming only the changed keys (possibly empty).
    public func patch(from original: SupermuxProjectDTO) -> SupermuxProjectPatch {
        var patch = SupermuxProjectPatch()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, trimmedName != original.name {
            patch.name = trimmedName
        }
        patch.colorHex = SupermuxPatchField.diff(
            from: original.colorHex,
            to: normalized(colorHex)
        )
        patch.iconSymbol = SupermuxPatchField.diff(
            from: original.iconSymbol,
            to: normalized(iconSymbol)
        )
        patch.defaultBranch = SupermuxPatchField.diff(
            from: original.defaultBranch,
            to: normalized(defaultBranch)
        )
        let sanitizedDir = Self.sanitizedWorktreesDirName(worktreesDirName)
        if sanitizedDir != (original.worktreesDirName ?? Self.defaultWorktreesDirName) {
            patch.worktreesDirName = sanitizedDir
        }
        // Config-owned fields are read-only on the phone (desktop parity):
        // even a programmatic text change never reaches the wire, so the Mac
        // can never answer `invalid_params` for them.
        guard !isConfigManaged else { return patch }
        let runCommands = Self.commandLines(runCommandsText)
        if runCommands != (original.runCommands ?? []) {
            patch.runCommands = runCommands
        }
        let setupCommands = Self.scriptEntries(setupScriptText)
        if setupCommands != (original.setupCommands ?? []) {
            patch.setupCommands = setupCommands
        }
        let teardownCommands = Self.scriptEntries(teardownScriptText)
        if teardownCommands != (original.teardownCommands ?? []) {
            patch.teardownCommands = teardownCommands
        }
        let cleanedActions = Self.cleanedActions(actions)
        if cleanedActions != (original.actions ?? []) {
            patch.actions = cleanedActions
        }
        return patch
    }

    // MARK: - Normalization (desktop-editor parity)

    /// Splits run-commands editor text into one command per non-blank line.
    static func commandLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Stores a setup/teardown editor's text as a single multi-line script
    /// entry (internal newlines preserved), or `[]` when blank.
    static func scriptEntries(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    /// Keeps the worktrees folder a single safe path component: strips path
    /// separators and falls back to the default for empty/`.`/`..` input, so
    /// it can never resolve outside the project root.
    static func sanitizedWorktreesDirName(_ text: String) -> String {
        let folder = text
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (folder.isEmpty || folder == "." || folder == "..") ? defaultWorktreesDirName : folder
    }

    /// Trims each action's fields and drops rows that cannot launch (blank
    /// name or command), matching the desktop editor's save filter.
    static func cleanedActions(_ actions: [SupermuxProjectActionDTO]) -> [SupermuxProjectActionDTO] {
        actions
            .map { action in
                var cleaned = action
                cleaned.name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
                cleaned.command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
                cleaned.iconSymbol = action.iconSymbol.flatMap { symbol in
                    let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return cleaned
            }
            .filter { !$0.name.isEmpty && !$0.command.isEmpty }
    }

    /// Trims and blank-collapses an optional field so the wire never carries
    /// empty strings.
    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

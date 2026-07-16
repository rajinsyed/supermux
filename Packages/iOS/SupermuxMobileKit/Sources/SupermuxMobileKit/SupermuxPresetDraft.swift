public import Foundation
public import SupermuxMobileCore

/// The typed `patch` object of `mobile.supermux.preset.update`, phone side.
///
/// Same patch semantics as ``SupermuxProjectPatch``: present keys only,
/// explicit `null` clears `icon_symbol`/`color_hex`, identity is immutable.
public struct SupermuxPresetPatch: Equatable, Sendable {
    /// New chip label (send non-empty only; the Mac rejects blank).
    public var name: String?
    /// New shell command (send non-empty only; the Mac rejects blank).
    public var command: String?
    /// SF Symbol; `.clear` removes it (neutral terminal glyph).
    public var iconSymbol: SupermuxPatchField<String>?
    /// Accent color `#RRGGBB`; `.clear` removes it (neutral chip style).
    public var colorHex: SupermuxPatchField<String>?

    /// Creates an empty patch; set only the fields the user changed.
    public init() {}

    /// Whether the patch names no keys at all (nothing to send).
    public var isEmpty: Bool {
        name == nil && command == nil && iconSymbol == nil && colorHex == nil
    }

    /// The exact wire `patch` object: present keys only, `NSNull` for clears.
    public var wireObject: [String: Any] {
        var object: [String: Any] = [:]
        if let name { object["name"] = name }
        if let command { object["command"] = command }
        if let iconSymbol { object["icon_symbol"] = iconSymbol.wireValue }
        if let colorHex { object["color_hex"] = colorHex.wireValue }
        return object
    }
}

/// The preset editor sheet's editable state, plus the create params / update
/// diff it saves through.
///
/// `preset.create` requires a non-empty name AND command (the Mac refuses an
/// unlaunchable chip), so ``createRequest()`` returns `nil` — and the sheet
/// keeps its Save button disabled — until both are filled, mirroring the
/// desktop's keep-the-row-local-until-launchable guidance.
public struct SupermuxPresetDraft: Equatable, Sendable {
    /// Chip label.
    public var name: String
    /// Shell command run in a new terminal when launched.
    public var command: String
    /// SF Symbol shown on the chip, or `nil` for the neutral default.
    public var iconSymbol: String?
    /// Accent color `#RRGGBB`, or `nil` for the neutral chip style.
    public var colorHex: String?

    /// Creates a blank draft (the create flow).
    public init() {
        name = ""
        command = ""
    }

    /// Seeds the draft from an existing preset (the edit flow).
    /// - Parameter preset: The preset as the Mac last reported it.
    public init(preset: SupermuxTerminalPresetDTO) {
        name = preset.name
        command = preset.command
        iconSymbol = preset.iconSymbol
        colorHex = preset.colorHex
    }

    /// Whether the draft can be created (both required fields non-blank).
    public var canSave: Bool {
        !trimmed(name).isEmpty && !trimmed(command).isEmpty
    }

    /// The `preset.create` request for this draft, or `nil` while a required
    /// field is blank.
    public func createRequest() -> SupermuxPresetCreateRequest? {
        let name = trimmed(name)
        let command = trimmed(command)
        guard !name.isEmpty, !command.isEmpty else { return nil }
        return SupermuxPresetCreateRequest(
            name: name,
            command: command,
            iconSymbol: normalized(iconSymbol),
            colorHex: normalized(colorHex)
        )
    }

    /// The present-key diff against the original record.
    /// - Parameter original: The preset the draft was seeded from.
    /// - Returns: A patch naming only the changed keys (possibly empty).
    public func patch(from original: SupermuxTerminalPresetDTO) -> SupermuxPresetPatch {
        var patch = SupermuxPresetPatch()
        let trimmedName = trimmed(name)
        if !trimmedName.isEmpty, trimmedName != original.name {
            patch.name = trimmedName
        }
        let trimmedCommand = trimmed(command)
        if !trimmedCommand.isEmpty, trimmedCommand != original.command {
            patch.command = trimmedCommand
        }
        patch.iconSymbol = SupermuxPatchField.diff(
            from: original.iconSymbol,
            to: normalized(iconSymbol)
        )
        patch.colorHex = SupermuxPatchField.diff(
            from: original.colorHex,
            to: normalized(colorHex)
        )
        return patch
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value.map(trimmed(_:)), !value.isEmpty else { return nil }
        return value
    }
}

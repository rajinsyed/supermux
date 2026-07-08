public import Foundation

/// Wire parsing for the `mobile.supermux.preset.*` write methods.
///
/// `preset.create` takes flat top-level params (`name`, `command`,
/// `icon_symbol?`, `color_hex?`) — the Mac assigns the identity, so a
/// client-sent id is never honored. `preset.update` takes a strict `patch`
/// object with the same patch semantics as the project patch: present keys
/// only, explicit `null` clears a nullable field, immutable and unknown keys
/// are rejected.
public struct SupermuxMobilePresetPatch: Sendable {
    /// New chip label (present ⇒ non-empty).
    public var name: String?
    /// New shell command (present ⇒ non-empty).
    public var command: String?
    /// SF Symbol; `.some(nil)` clears it (neutral terminal glyph).
    public var iconSymbol: String??
    /// Accent color; `.some(nil)` clears it (neutral chip style).
    public var colorHex: String??

    /// Parses the wire patch object, rejecting immutable, unknown, and
    /// malformed keys.
    /// - Parameter wire: The request's `patch` object.
    public init(wire: [String: Any]) throws {
        let allowedKeys: Set<String> = ["name", "command", "icon_symbol", "color_hex"]
        for key in wire.keys where !allowedKeys.contains(key) {
            if key == "id" || key == "preset_id" {
                throw SupermuxMobilePatchError.immutableKey(key)
            }
            throw SupermuxMobilePatchError.unknownKey(key)
        }
        name = try SupermuxMobileWireValue.string(wire, key: "name")
        command = try SupermuxMobileWireValue.string(wire, key: "command")
        iconSymbol = try SupermuxMobileWireValue.nullableString(wire, key: "icon_symbol")
        colorHex = try SupermuxMobileWireValue.nullableString(wire, key: "color_hex")
    }

    /// Applies the patch: present keys only; identity is preserved.
    /// - Parameter preset: The current preset record.
    /// - Returns: The patched record (same `id`).
    public func applied(to preset: SupermuxTerminalPreset) -> SupermuxTerminalPreset {
        var copy = preset
        if let name { copy.name = name }
        if let command { copy.command = command }
        if let iconSymbol { copy.iconSymbol = iconSymbol }
        if let colorHex { copy.colorHex = colorHex }
        return copy
    }

    /// Builds a fresh preset from `mobile.supermux.preset.create` params.
    ///
    /// `name` and `command` are required non-empty (a chip that cannot launch
    /// is useless to create remotely); `icon_symbol` / `color_hex` are
    /// optional. Extra top-level params (transport context such as
    /// `window_id`) are ignored, matching the other mobile handlers.
    /// - Parameter params: The request params.
    /// - Returns: The preset to add (fresh Mac-assigned identity).
    public static func createPreset(fromWire params: [String: Any]) throws -> SupermuxTerminalPreset {
        guard params["name"] != nil else { throw SupermuxMobilePatchError.missingKey("name") }
        guard params["command"] != nil else { throw SupermuxMobilePatchError.missingKey("command") }
        guard let name = try SupermuxMobileWireValue.string(params, key: "name"),
              let command = try SupermuxMobileWireValue.string(params, key: "command") else {
            // Unreachable: presence was checked above and `string` only
            // returns nil for absent keys. Kept for exhaustiveness.
            throw SupermuxMobilePatchError.missingKey("name")
        }
        let iconSymbol = try SupermuxMobileWireValue.nullableString(params, key: "icon_symbol") ?? nil
        let colorHex = try SupermuxMobileWireValue.nullableString(params, key: "color_hex") ?? nil
        return SupermuxTerminalPreset(
            name: name,
            command: command,
            iconSymbol: iconSymbol,
            colorHex: colorHex
        )
    }
}

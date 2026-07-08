/// Wire representation of a global terminal preset (one-click launcher chip).
///
/// Mirrors the Mac's `SupermuxTerminalPreset` model.
public struct SupermuxTerminalPresetDTO: Codable, Sendable, Equatable {
    /// Stable preset identity (UUID string).
    public var id: String
    /// User-visible label shown on the chip.
    public var name: String
    /// Shell command run in a new terminal when launched.
    public var command: String
    /// SF Symbol shown on the chip, or `nil` for the neutral default.
    public var iconSymbol: String?
    /// Accent color as `#RRGGBB`, or `nil` for the neutral chip style.
    public var colorHex: String?

    /// Creates a preset DTO.
    /// - Parameters:
    ///   - id: Stable preset identity (UUID string).
    ///   - name: Display label.
    ///   - command: Shell command to run when launched.
    ///   - iconSymbol: Optional SF Symbol name.
    ///   - colorHex: Optional `#RRGGBB` accent.
    public init(
        id: String,
        name: String,
        command: String,
        iconSymbol: String? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case iconSymbol = "icon_symbol"
        case colorHex = "color_hex"
    }
}

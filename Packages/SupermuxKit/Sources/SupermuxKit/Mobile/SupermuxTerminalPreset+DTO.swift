public import SupermuxMobileCore

extension SupermuxTerminalPresetDTO {
    /// Maps a Mac-side terminal preset onto its wire DTO.
    /// - Parameter preset: The Mac-side preset record.
    public init(preset: SupermuxTerminalPreset) {
        self.init(
            id: preset.id.uuidString,
            name: preset.name,
            command: preset.command,
            iconSymbol: preset.iconSymbol,
            colorHex: preset.colorHex
        )
    }
}

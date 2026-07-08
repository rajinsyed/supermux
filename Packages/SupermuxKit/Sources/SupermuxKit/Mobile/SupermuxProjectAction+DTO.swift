public import SupermuxMobileCore

extension SupermuxProjectActionDTO {
    /// Maps a Mac-side project action onto its wire DTO.
    ///
    /// `kind`/`url` stay `nil`: the Mac model has no `open_url` actions today,
    /// and an absent `kind` means a plain command on the wire.
    ///
    /// - Parameter action: The Mac-side action record.
    public init(action: SupermuxProjectAction) {
        self.init(
            id: action.id.uuidString,
            name: action.name,
            command: action.command,
            iconSymbol: action.iconSymbol
        )
    }
}

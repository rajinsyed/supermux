public import Foundation
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

extension SupermuxProjectAction {
    /// Maps a wire action DTO onto the Mac model (used by the
    /// `project.update` patch's whole-array `actions` replacement).
    ///
    /// Returns `nil` — the caller rejects the patch with `invalid_params` —
    /// when the DTO cannot be represented: a non-UUID `id`, a blank name or
    /// command, or a `kind` other than a plain command (the Mac model has no
    /// `open_url` actions to store).
    /// - Parameter dto: The wire action.
    public init?(dto: SupermuxProjectActionDTO) {
        guard dto.kind == nil || dto.kind == "command" else { return nil }
        guard let id = UUID(uuidString: dto.id) else { return nil }
        let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = dto.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return nil }
        let icon = dto.iconSymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: id,
            name: name,
            command: command,
            iconSymbol: (icon?.isEmpty ?? true) ? nil : icon
        )
    }
}

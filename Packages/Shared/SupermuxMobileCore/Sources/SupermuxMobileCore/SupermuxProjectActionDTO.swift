/// Wire representation of a named, launchable command attached to a project.
///
/// Mirrors the Mac's `SupermuxProjectAction` model. ``kind`` distinguishes
/// plain commands (executed Mac-side by ``SupermuxMobileMethod/actionRun``)
/// from `open_url` actions, whose ``url`` the phone opens locally.
public struct SupermuxProjectActionDTO: Codable, Sendable, Equatable {
    /// Stable action identity (UUID string).
    public var id: String
    /// User-visible label shown in menus.
    public var name: String
    /// Shell command executed when the action is launched.
    public var command: String
    /// SF Symbol shown next to the action, or `nil` for the default glyph.
    public var iconSymbol: String?
    /// Action kind (`"command"` or `"open_url"`); absent means `"command"`.
    public var kind: String?
    /// The URL an `open_url` action opens; `nil` for command actions.
    public var url: String?

    /// Creates an action DTO.
    /// - Parameters:
    ///   - id: Stable action identity (UUID string).
    ///   - name: Display label.
    ///   - command: Shell command to run.
    ///   - iconSymbol: Optional SF Symbol name.
    ///   - kind: Optional action kind (`"command"` / `"open_url"`).
    ///   - url: Optional URL for `open_url` actions.
    public init(
        id: String,
        name: String,
        command: String,
        iconSymbol: String? = nil,
        kind: String? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.iconSymbol = iconSymbol
        self.kind = kind
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case iconSymbol = "icon_symbol"
        case kind
        case url
    }
}

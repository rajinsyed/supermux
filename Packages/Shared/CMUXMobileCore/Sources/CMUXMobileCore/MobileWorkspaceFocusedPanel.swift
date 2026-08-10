// SUPERMUX:begin supermux-mobile-selection-sync
/// The panel currently focused inside a mobile-synced workspace.
///
/// `kind` uses the Mac panel-type wire value (`terminal`, `browser`,
/// `simulator`, and so on). Keeping it string-backed lets older phones ignore
/// panel kinds they cannot render while still preserving the focused identity.
public struct MobileWorkspaceFocusedPanel: Codable, Equatable, Sendable {
    /// Stable panel UUID string.
    public let panelID: String
    /// Forward-compatible Mac panel-type wire value.
    public let kind: String

    /// Creates a focused-panel value.
    /// - Parameters:
    ///   - panelID: Stable panel UUID string.
    ///   - kind: Mac panel-type wire value.
    public init(panelID: String, kind: String) {
        self.panelID = panelID
        self.kind = kind
    }

    /// Terminal panel kind.
    public static let terminalKind = "terminal"
    /// Browser panel kind.
    public static let browserKind = "browser"
    /// Simulator panel kind.
    public static let simulatorKind = "simulator"

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case kind
    }
}
// SUPERMUX:end supermux-mobile-selection-sync

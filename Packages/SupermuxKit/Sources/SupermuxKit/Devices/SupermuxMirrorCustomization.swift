public import Foundation

/// A remote workspace's custom color, description and pin, as its Mac
/// reports them. The mirror status projection copies each field onto the
/// local mirror only when the remote value changed since the one it last
/// applied, so a local edit on the mirror holds until the owning Mac changes
/// that field again. ``SupermuxDeviceBindingStore`` persists the last applied
/// value per mirror, so that promise also holds across app restarts.
public struct SupermuxMirrorCustomization: Codable, Equatable, Sendable {
    public var colorHex: String?
    public var description: String?
    public var isPinned: Bool

    public init(colorHex: String?, description: String?, isPinned: Bool) {
        self.colorHex = colorHex
        self.description = description
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case colorHex = "color_hex"
        case description
        case isPinned = "is_pinned"
    }
}

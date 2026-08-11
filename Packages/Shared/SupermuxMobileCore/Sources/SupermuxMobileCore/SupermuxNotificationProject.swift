import Foundation

/// The project identity attached to one notification, shared verbatim by every
/// surface that renders it: the Mac notifications panel, the Mac system banner,
/// the iOS feed, and the APNs push payload.
///
/// This is a *snapshot*, resolved on the Mac at notification time — never a
/// live reference to ``SupermuxProject``. A notification keeps showing the
/// project it fired from even after the project is renamed, recolored, or
/// unregistered, which is what makes the feed readable when scrolling back
/// through history.
///
/// Nothing here is optional-by-accident: a notification from a workspace that
/// belongs to no project simply carries no identity at all (`nil`), and every
/// surface degrades to the same project-less layout it rendered before
/// projects existed.
public struct SupermuxNotificationProject: Codable, Sendable, Equatable, Hashable {
    /// Stable project identity (UUID string). Also the grouping key: the Mac
    /// banner's `threadIdentifier` and the push `thread-id`, so the system
    /// stacks a project's notifications together in Notification Center.
    public var id: String
    /// The project's display name at notification time.
    public var name: String
    /// Explicit accent as `#RRGGBB`, or `nil` when the project never got one
    /// (renderers derive a stable accent from ``id`` instead — see
    /// ``SupermuxProjectAccentPalette``).
    public var colorHex: String?
    /// SF Symbol avatar name, or `nil` for the letter avatar.
    public var iconSymbol: String?
    /// Change token for the project's icon image, mirroring
    /// ``SupermuxProjectDTO/iconETag``. Present only when an icon image is
    /// actually fetchable, so a consumer can both (a) know an image exists and
    /// (b) re-fetch exactly when the bytes changed.
    public var iconETag: String?

    /// Creates a notification's project identity snapshot.
    /// - Parameters:
    ///   - id: Stable project identity (UUID string).
    ///   - name: Display name at notification time.
    ///   - colorHex: Explicit `#RRGGBB` accent, or `nil` to derive from `id`.
    ///   - iconSymbol: SF Symbol avatar name, or `nil` for a letter avatar.
    ///   - iconETag: Icon-image change token; `nil` when no image is fetchable.
    public init(
        id: String,
        name: String,
        colorHex: String? = nil,
        iconSymbol: String? = nil,
        iconETag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
        self.iconETag = iconETag
    }

    /// Whether an icon image exists for this project on the Mac.
    public var hasIconImage: Bool {
        guard let iconETag else { return false }
        return !iconETag.isEmpty
    }

    /// The uppercased first character of ``name``, for the letter avatar.
    /// Falls back to `"?"` for a blank or symbol-only name so the avatar is
    /// never empty.
    public var avatarLetter: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorHex = "color_hex"
        case iconSymbol = "icon_symbol"
        case iconETag = "icon_etag"
    }
}

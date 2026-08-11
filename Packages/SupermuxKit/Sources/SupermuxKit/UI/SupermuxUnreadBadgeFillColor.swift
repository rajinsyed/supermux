public import SwiftUI

/// Environment fill color for the unread badge on project-nested workspace
/// rows, so they honor the same user-settable badge color (Settings →
/// workspace colors) as cmux's flat sidebar rows instead of hardcoding the
/// accent. Injected by the app-target mount; package previews and tests fall
/// back to the accent tint, matching the setting's own default.
public struct SupermuxUnreadBadgeFillColorKey: EnvironmentKey {
    public static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    /// Unread badge capsule fill for the Projects section's nested rows. See
    /// ``SupermuxUnreadBadgeFillColorKey``.
    public var supermuxUnreadBadgeFillColor: Color {
        get { self[SupermuxUnreadBadgeFillColorKey.self] }
        set { self[SupermuxUnreadBadgeFillColorKey.self] = newValue }
    }
}

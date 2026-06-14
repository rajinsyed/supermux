public import SwiftUI

/// Environment multiplier applied to the Projects section's text and avatar
/// sizes so cmux's `sidebar-font-size` setting scales project rows and their
/// nested workspaces exactly like the flat workspace list. `1` is the default
/// sidebar font size; values above `1` enlarge the section, below `1` shrink it.
///
/// Injected by the app-target mount from the live sidebar font size (see
/// `SupermuxSidebarFontScaleStore`). Package previews and tests fall back to the
/// `1.0` default, so rows render at their design sizes without any host wiring.
public struct SupermuxSidebarFontScaleKey: EnvironmentKey {
    public static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Font/avatar size multiplier for the supermux Projects section. See
    /// ``SupermuxSidebarFontScaleKey``.
    public var supermuxSidebarFontScale: CGFloat {
        get { self[SupermuxSidebarFontScaleKey.self] }
        set { self[SupermuxSidebarFontScaleKey.self] = newValue }
    }
}

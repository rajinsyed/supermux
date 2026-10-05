import Foundation
public import SupermuxMobileCore

/// The words for a remote Mac's route on this Mac: `Direct · LAN · 6 ms`,
/// `Direct · Tailscale · 8 ms`, `Relay · Tokyo · 241 ms`.
///
/// The phone's wording (`SupermuxLinkRouteCaption` in SupermuxMobileUI) with
/// the same keys, resolved against the app catalog
/// (`Resources/Localizable.xcstrings`) like every macOS package string.
public enum SupermuxLinkRouteText {
    /// The words for a route.
    /// - Parameter route: The route.
    /// - Returns: The localized text.
    public static func text(for route: SupermuxLinkRoute) -> String {
        ""
    }

    /// Whether the route warns (amber): it goes through a relay.
    /// - Parameter route: The route.
    public static func isWarning(_ route: SupermuxLinkRoute) -> Bool {
        false
    }
}

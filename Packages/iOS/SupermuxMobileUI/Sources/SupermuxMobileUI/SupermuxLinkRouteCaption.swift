import Foundation
public import SupermuxMobileCore

/// The words for a route: `Direct · LAN · 6 ms`, `Direct · Tailscale · 8 ms`,
/// `Relay · Tokyo · 241 ms`.
///
/// Kind, then where (the direct path's network, or the relay's place), then
/// iroh's round trip when it has one. A relay place is localized by its id;
/// an id the table does not know shows itself upper-cased.
public enum SupermuxLinkRouteCaption {
    /// The caption for a route.
    /// - Parameter route: The route.
    /// - Returns: The localized caption.
    public static func text(for route: SupermuxLinkRoute) -> String {
        ""
    }

    /// Whether the caption warns (tinted): the route goes through a relay.
    /// - Parameter route: The route.
    public static func isWarning(_ route: SupermuxLinkRoute) -> Bool {
        false
    }
}

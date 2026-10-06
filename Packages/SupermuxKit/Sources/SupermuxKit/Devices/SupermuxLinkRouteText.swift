import Foundation
public import SupermuxMobileCore

/// The words for a remote Mac's route on this Mac: `Direct · LAN · 6 ms`,
/// `Direct · Tailscale · 8 ms`, `Relay · Tokyo · 241 ms`.
///
/// The phone's wording (`SupermuxLinkRouteCaption` in SupermuxMobileUI) with
/// the same keys, resolved against the app catalog
/// (`Resources/Localizable.xcstrings`) like every macOS package string: kind,
/// then where (the direct path's network, or the relay's place), then iroh's
/// round trip when it has one. A relay place is localized by its id
/// (``SupermuxRelayPlace``: the city where it is confirmed, the region where
/// the city is only assumed); an id the table does not know shows itself
/// upper-cased. "Tailscale" is a brand and stays as is.
public enum SupermuxLinkRouteText {
    /// The words for a route.
    /// - Parameter route: The route.
    /// - Returns: The localized text.
    public static func text(for route: SupermuxLinkRoute) -> String {
        var parts = [kind(route)]
        if let place = place(route) { parts.append(place) }
        if let rtt = route.rttMs {
            parts.append(String(localized: "supermux.route.rtt", defaultValue: "\(rtt) ms"))
        }
        return join(parts)
    }

    /// Whether the route warns (amber): it goes through a relay.
    /// - Parameter route: The route.
    public static func isWarning(_ route: SupermuxLinkRoute) -> Bool {
        route.isRelay
    }

    private static func kind(_ route: SupermuxLinkRoute) -> String {
        route.isRelay
            ? String(localized: "supermux.route.kind.relay", defaultValue: "Relay")
            : String(localized: "supermux.route.kind.direct", defaultValue: "Direct")
    }

    private static func place(_ route: SupermuxLinkRoute) -> String? {
        switch route.kind {
        case .direct(.lan):
            String(localized: "supermux.route.scope.lan", defaultValue: "LAN")
        case .direct(.tailscale):
            String(localized: "supermux.route.scope.tailscale", defaultValue: "Tailscale")
        case .direct(.internet):
            String(localized: "supermux.route.scope.internet", defaultValue: "Internet")
        case .relay:
            route.relayPlace.map(relayPlace)
        }
    }

    private static func relayPlace(_ place: SupermuxRelayPlace) -> String {
        switch place.id {
        case "apne1": String(localized: "supermux.route.place.apne1", defaultValue: "Tokyo")
        case "apse1": String(localized: "supermux.route.place.apse1", defaultValue: "Singapore")
        case "ape1": String(localized: "supermux.route.place.ape1", defaultValue: "Taiwan")
        case "usc1": String(localized: "supermux.route.place.usc1", defaultValue: "US Central")
        case "usw1": String(localized: "supermux.route.place.usw1", defaultValue: "US West")
        case "use4": String(localized: "supermux.route.place.use4", defaultValue: "US East")
        case "euw4": String(localized: "supermux.route.place.euw4", defaultValue: "Europe West")
        default: place.displayName
        }
    }

    private static func join(_ parts: [String]) -> String {
        switch parts.count {
        case 3:
            String(localized: "supermux.route.threeParts", defaultValue: "\(parts[0]) · \(parts[1]) · \(parts[2])")
        case 2:
            String(localized: "supermux.route.twoParts", defaultValue: "\(parts[0]) · \(parts[1])")
        default:
            parts.first ?? ""
        }
    }
}

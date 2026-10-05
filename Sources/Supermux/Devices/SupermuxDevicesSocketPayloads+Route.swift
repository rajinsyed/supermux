import Foundation
import SupermuxMobileCore

extension SupermuxDevicesSocketPayloads {
    /// A link's route in `supermux.devices.list`: `{kind: direct|relay,
    /// scope: lan|tailscale|internet|null, relay_id, place, city, region,
    /// place_confidence: confirmed|best_effort|unknown|null, rtt_ms, since_ms}`,
    /// or null while the link has none (not connected, no path selected).
    static func route(_ route: SupermuxLinkRoute?) -> Any {
        guard let route else { return NSNull() }
        let place = route.relayPlace
        return [
            "kind": route.isRelay ? "relay" : "direct",
            "scope": route.scope?.rawValue ?? NSNull(),
            "relay_id": route.relayID ?? NSNull(),
            "place": place?.displayName ?? NSNull(),
            "city": place?.city ?? NSNull(),
            "region": place?.region ?? NSNull(),
            "place_confidence": place?.confidence.rawValue ?? NSNull(),
            "rtt_ms": route.rttMs ?? NSNull(),
            "since_ms": Int64(route.since.timeIntervalSince1970 * 1000),
        ] as [String: Any]
    }
}

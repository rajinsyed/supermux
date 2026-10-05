import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// The words under each Mac in the Projects list: direct or relay, and where
/// (W8). Failure modes, listed before the code:
///
/// 1. A Tailscale path reads as LAN (or the other way round).
/// 2. A relay shows its host label (`apne1`) instead of its place (Tokyo).
/// 3. A relay whose city is only assumed shows a city that may be wrong.
/// 4. An unknown relay shows nothing, or crashes the lookup.
/// 5. A route with no RTT yet shows `nil ms` or a dangling separator.
/// 6. A relay with no URL shows an empty place.
/// 7. A direct route is tinted like a warning, or a relay is not.
/// 8. A new key misses one of the nine locales.
@Suite struct SupermuxLinkRouteCaptionTests {
    private let since = Date(timeIntervalSince1970: 0)

    private func route(_ kind: SupermuxLinkRoute.Kind, rtt: Int?) -> SupermuxLinkRoute {
        SupermuxLinkRoute(kind: kind, rttMs: rtt, since: since)
    }

    @Test func directPathsNameTheirNetwork() {
        #expect(SupermuxLinkRouteCaption.text(for: route(.direct(.lan), rtt: 6)) == "Direct · LAN · 6 ms")
        #expect(SupermuxLinkRouteCaption.text(for: route(.direct(.tailscale), rtt: 8)) == "Direct · Tailscale · 8 ms")
        #expect(SupermuxLinkRouteCaption.text(for: route(.direct(.internet), rtt: 40)) == "Direct · Internet · 40 ms")
    }

    @Test func aRelayNamesItsPlace() {
        #expect(SupermuxLinkRouteCaption.text(for: route(.relay(id: "apne1"), rtt: 241)) == "Relay · Tokyo · 241 ms")
        #expect(SupermuxLinkRouteCaption.text(for: route(.relay(id: "apse1"), rtt: 90)) == "Relay · Singapore · 90 ms")
    }

    @Test func aRelayWithAnAssumedCityShowsItsRegion() {
        #expect(SupermuxLinkRouteCaption.text(for: route(.relay(id: "usc1"), rtt: 120)) == "Relay · US Central · 120 ms")
    }

    @Test func anUnknownRelayShowsItsID() {
        #expect(SupermuxLinkRouteCaption.text(for: route(.relay(id: "xyz9"), rtt: 300)) == "Relay · XYZ9 · 300 ms")
    }

    @Test func noRTTYetLeavesItOut() {
        #expect(SupermuxLinkRouteCaption.text(for: route(.direct(.lan), rtt: nil)) == "Direct · LAN")
        #expect(SupermuxLinkRouteCaption.text(for: route(.relay(id: "apne1"), rtt: nil)) == "Relay · Tokyo")
    }

    @Test func aRelayWithoutAURLSaysRelay() {
        #expect(SupermuxLinkRouteCaption.text(for: route(.relay(id: nil), rtt: 241)) == "Relay · 241 ms")
        #expect(SupermuxLinkRouteCaption.text(for: route(.relay(id: nil), rtt: nil)) == "Relay")
    }

    @Test func onlyARelayIsAWarning() {
        #expect(SupermuxLinkRouteCaption.isWarning(route(.relay(id: "apne1"), rtt: 241)))
        #expect(!SupermuxLinkRouteCaption.isWarning(route(.direct(.lan), rtt: 6)))
        #expect(!SupermuxLinkRouteCaption.isWarning(route(.direct(.internet), rtt: 60)))
    }

    @Test func everyRouteKeyCarriesAllNineLocales() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SupermuxMobileUI/Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        let routeKeys = strings.keys.filter { $0.hasPrefix("supermux.route.") }
        #expect(routeKeys.count >= 14, "expected the route kind, network, place and format keys")
        for key in routeKeys {
            let localizations = strings[key]?["localizations"] as? [String: [String: Any]] ?? [:]
            for locale in ["en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"] {
                let unit = localizations[locale]?["stringUnit"] as? [String: Any]
                #expect((unit?["value"] as? String)?.isEmpty == false, "\(key) is missing \(locale)")
            }
        }
    }
}

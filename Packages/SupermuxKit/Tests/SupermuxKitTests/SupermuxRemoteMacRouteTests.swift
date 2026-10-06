import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// What this Mac shows about the path to another Mac: "Direct · LAN · 6 ms"
/// or "Relay · Tokyo · 241 ms" in the sidebar icon's tooltip and the Remote
/// Macs row, and an amber dot on the icon only while relayed (W3). Failure
/// modes, listed before the code:
///
/// 1. A Tailscale path reads as LAN (or the other way round), or a direct
///    path names a relay.
/// 2. A relay shows its host label (`apne1`) instead of its place (Tokyo).
/// 3. A relay whose city is only assumed shows a city that may be wrong
///    instead of its region.
/// 4. An unknown relay shows nothing, or crashes the lookup.
/// 5. A route with no RTT yet shows `nil ms`, `0 ms` or a dangling separator.
/// 6. A relay with no URL shows an empty place.
/// 7. The Mac's words differ from the phone's for the same route.
/// 8. A connected Mac's tooltip loses "On <Mac>", with or without a route.
/// 9. A Mac that is connecting or offline shows a stale route instead of its
///    status.
/// 10. The amber dot shows on a direct route, or never on a relay.
/// 11. The amber dot shows on a dimmed (connecting or offline) icon from a
///     stale relay route.
/// 12. Two same-named Macs: the offline one's stale route wins over the
///     connected one's; a name no device carries borrows another Mac's route.
/// 13. A route, tooltip or diagnostics key misses one of the nine locales in
///     the app catalog, or a translation drops a placeholder.
@Suite struct SupermuxRemoteMacRouteTests {
    private let since = Date(timeIntervalSince1970: 0)

    private func route(_ kind: SupermuxLinkRoute.Kind, rtt: Int?) -> SupermuxLinkRoute {
        SupermuxLinkRoute(kind: kind, rttMs: rtt, since: since)
    }

    // MARK: - The words (1–7)

    @Test func directPathsNameTheirNetwork() {
        #expect(SupermuxLinkRouteText.text(for: route(.direct(.lan), rtt: 6)) == "Direct · LAN · 6 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.direct(.tailscale), rtt: 8)) == "Direct · Tailscale · 8 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.direct(.internet), rtt: 40)) == "Direct · Internet · 40 ms")
    }

    @Test func aRelayNamesItsPlace() {
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "apne1"), rtt: 241)) == "Relay · Tokyo · 241 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "apse1"), rtt: 90)) == "Relay · Singapore · 90 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "ape1"), rtt: 60)) == "Relay · Taiwan · 60 ms")
    }

    @Test func aRelayWithAnAssumedCityShowsItsRegion() {
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "usc1"), rtt: 120)) == "Relay · US Central · 120 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "usw1"), rtt: 120)) == "Relay · US West · 120 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "use4"), rtt: 120)) == "Relay · US East · 120 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "euw4"), rtt: 120)) == "Relay · Europe West · 120 ms")
    }

    @Test func anUnknownRelayShowsItsID() {
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "xyz9"), rtt: 300)) == "Relay · XYZ9 · 300 ms")
    }

    @Test func noRTTYetLeavesItOut() {
        #expect(SupermuxLinkRouteText.text(for: route(.direct(.lan), rtt: nil)) == "Direct · LAN")
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: "apne1"), rtt: nil)) == "Relay · Tokyo")
        #expect(SupermuxLinkRouteText.text(for: route(.direct(.lan), rtt: 0)) == "Direct · LAN · 0 ms")
    }

    @Test func aRelayWithoutAURLSaysRelay() {
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: nil), rtt: 241)) == "Relay · 241 ms")
        #expect(SupermuxLinkRouteText.text(for: route(.relay(id: nil), rtt: nil)) == "Relay")
    }

    @Test func onlyARelayWarns() {
        #expect(SupermuxLinkRouteText.isWarning(route(.relay(id: "apne1"), rtt: 241)))
        #expect(SupermuxLinkRouteText.isWarning(route(.relay(id: nil), rtt: nil)))
        #expect(!SupermuxLinkRouteText.isWarning(route(.direct(.lan), rtt: 6)))
        #expect(!SupermuxLinkRouteText.isWarning(route(.direct(.internet), rtt: 60)))
    }

    // MARK: - The icon's tooltip and dot (8–11)

    @Test func aConnectedMacsTooltipCarriesItsRoute() {
        let relayed = route(.relay(id: "apne1"), rtt: 241)
        #expect(SupermuxRemoteMacIcon.helpText(name: "MacBook Pro", state: .online, route: relayed)
            == "On MacBook Pro — Relay · Tokyo · 241 ms")
        let tailscale = route(.direct(.tailscale), rtt: 8)
        #expect(SupermuxRemoteMacIcon.helpText(name: "Studio", state: .online, route: tailscale)
            == "On Studio — Direct · Tailscale · 8 ms")
    }

    @Test func aConnectedMacWithoutARouteKeepsItsName() {
        #expect(SupermuxRemoteMacIcon.helpText(name: "MacBook Pro", state: .online, route: nil) == "On MacBook Pro")
    }

    @Test func anUnreachableMacShowsItsStatusNotAStaleRoute() {
        let stale = route(.relay(id: "apne1"), rtt: 241)
        #expect(SupermuxRemoteMacIcon.helpText(name: "MacBook Pro", state: .connecting, route: stale)
            == "On MacBook Pro — Connecting…")
        #expect(SupermuxRemoteMacIcon.helpText(name: "MacBook Pro", state: .offline, route: stale)
            == "On MacBook Pro — Offline")
    }

    @Test func theAmberDotMarksOnlyALiveRelay() {
        let relayed = route(.relay(id: "apne1"), rtt: 241)
        #expect(SupermuxRemoteMacIcon.showsRelayDot(state: .online, route: relayed))
        #expect(!SupermuxRemoteMacIcon.showsRelayDot(state: .online, route: route(.direct(.lan), rtt: 6)))
        #expect(!SupermuxRemoteMacIcon.showsRelayDot(state: .online, route: route(.direct(.tailscale), rtt: 8)))
        #expect(!SupermuxRemoteMacIcon.showsRelayDot(state: .online, route: nil))
        #expect(!SupermuxRemoteMacIcon.showsRelayDot(state: .connecting, route: relayed))
        #expect(!SupermuxRemoteMacIcon.showsRelayDot(state: .offline, route: relayed))
    }

    // MARK: - Which Mac's route a flat row shows (12)

    private func mac(
        _ name: String, _ state: SupermuxDeviceChipState, id: String, route: SupermuxLinkRoute? = nil
    ) -> SupermuxDeviceChipState.Candidate {
        SupermuxDeviceChipState.Candidate(name: name, machineID: id, state: state, route: route)
    }

    @Test func theConnectedSameNamedMacsRouteWins() {
        let live = route(.direct(.lan), rtt: 6)
        let stale = route(.relay(id: "apne1"), rtt: 241)
        let devices = [mac("MacBook", .offline, id: "a", route: stale), mac("MacBook", .online, id: "b", route: live)]
        #expect(SupermuxDeviceChipState.resolveRoute(name: "MacBook", among: devices) == live)
    }

    @Test func noConnectedMacMeansNoRoute() {
        let stale = route(.relay(id: "apne1"), rtt: 241)
        #expect(SupermuxDeviceChipState.resolveRoute(name: "MacBook", among: [mac("MacBook", .connecting, id: "a", route: stale)]) == nil)
        #expect(SupermuxDeviceChipState.resolveRoute(name: "MacBook", among: [mac("MacBook", .online, id: "a")]) == nil)
    }

    @Test func aNameNoDeviceCarriesBorrowsNoRoute() {
        let other = route(.relay(id: "apne1"), rtt: 241)
        #expect(SupermuxDeviceChipState.resolveRoute(name: "Studio", among: [mac("MacBook", .online, id: "a", route: other)]) == nil)
        #expect(SupermuxDeviceChipState.resolveRoute(name: "  ", among: [mac("", .online, id: "x", route: other)]) == nil)
    }

    @Test func theRouteFollowsTheNameAndTheMachineIDFallback() {
        let live = route(.direct(.tailscale), rtt: 8)
        let devices = [mac("MacBook", .online, id: "device:1234@stable", route: live)]
        #expect(SupermuxDeviceChipState.resolveRoute(name: " MacBook ", among: devices) == live)
        #expect(SupermuxDeviceChipState.resolveRoute(name: "device:1234@stable", among: devices) == live)
    }

    // MARK: - The app catalog (13)

    @Test func everyNewMacKeyCarriesAllNineLocales() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        let keys = strings.keys.filter {
            $0.hasPrefix("supermux.route.") || $0.hasPrefix("supermux.diag.links.") || $0 == "supermux.devices.chip.route"
        }
        #expect(keys.filter { $0.hasPrefix("supermux.route.") }.count >= 15, "expected the phone's route keys")
        #expect(keys.contains("supermux.devices.chip.route"))
        #expect(keys.contains { $0.hasPrefix("supermux.diag.links.") }, "expected the iroh-diag section's headings")
        let placeholder = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|@)")
        func placeholders(_ text: String) -> Int {
            placeholder.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        for key in keys {
            let localizations = strings[key]?["localizations"] as? [String: [String: Any]] ?? [:]
            let english = (localizations["en"]?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            for locale in ["en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"] {
                let value = (localizations[locale]?["stringUnit"] as? [String: Any])?["value"] as? String
                #expect(value?.isEmpty == false, "\(key) is missing \(locale)")
                #expect(value.map(placeholders) == placeholders(english), "\(key) \(locale) drops a placeholder")
            }
        }
    }
}

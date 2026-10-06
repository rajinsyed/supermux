import Foundation
import Testing
@testable import SupermuxMobileCore

/// Ways the route a device link reports ("Direct · LAN", "Relay · Tokyo")
/// could be wrong, written before the classifier:
/// 1. A Tailscale IPv4 peer (`100.64.0.0/10`) read as LAN, or as Internet.
/// 2. A Tailscale IPv6 peer (`fd7a:115c:a1e0::/48`) read as a LAN ULA
///    (`fc00::/7` checked before Tailscale).
/// 3. A Tailscale service address (`100.100.100.100`, MagicDNS) counted as a peer.
/// 4. A link-local IPv6 path with a zone (`[fe80::1%en0]:port`, or Rust's
///    numeric `%14`) failing to parse and falling to Internet.
/// 5. An IPv4-mapped IPv6 address (`[::ffff:192.168.1.5]`) read as Internet IPv6.
/// 6. A relay URL with or without its trailing slash, in upper case or with a
///    trailing dot, giving different relay ids.
/// 7. An unknown relay id shown as a wrong city instead of its own id.
/// 8. A relay whose city is only assumed (the US and EU ids) shown as that city.
/// 9. A missing RTT turned into 0 ms, or an absurd one overflowing.
/// 10. A malformed address (no port, port 0, garbage, a non-canonical
///     `010.0.0.1`) crashing or classified as LAN.
/// 11. RFC 1918 edges: `172.16/12` is LAN, `172.32.0.1` is not.
/// 12. A relay path whose address is not a URL losing its relay kind.
/// 13. Publishing: RTT jitter republishing every 2 s sample, a kind change
///     waiting behind the RTT throttle, a large RTT move published within 5 s
///     of the last one, and `since` reset by an RTT-only update.
@Suite struct SupermuxLinkRouteClassifierTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func direct(_ address: String) -> SupermuxLinkRoute.Scope? {
        SupermuxLinkRouteClassifier.classify(isRelay: false, remoteAddress: address, rttMs: 6, now: now).scope
    }

    // MARK: Direct scopes

    @Test func tailscaleIPv4IsTailscaleNotLAN() {
        #expect(direct("100.64.0.1:58465") == .tailscale)
        #expect(direct("100.69.64.102:58465") == .tailscale)
        #expect(direct("100.127.255.254:1") == .tailscale)
    }

    @Test func tailscaleIPv6IsTailscaleNotULA() {
        #expect(direct("[fd7a:115c:a1e0::1]:58465") == .tailscale)
        #expect(direct("[fd7a:115c:a1e0:ab12:4843:cd96:6258:b240]:41641") == .tailscale)
        #expect(direct("[fd00::1]:58465") == .lan)
    }

    @Test func tailscaleServiceAddressesAreNotPeers() {
        #expect(direct("100.100.100.100:53") == .internet)
        #expect(direct("[fd7a:115c:a1e0::53]:53") == .lan)
    }

    @Test func linkLocalWithZoneParses() {
        #expect(direct("[fe80::1%en0]:58465") == .lan)
        #expect(direct("[fe80::1c2b:3d4e:5f60:7182%14]:58465") == .lan)
        #expect(direct("169.254.10.20:58465") == .lan)
    }

    @Test func ipv4MappedIPv6UsesItsIPv4Scope() {
        #expect(direct("[::ffff:192.168.1.5]:58465") == .lan)
        #expect(direct("[::ffff:100.70.1.2]:58465") == .tailscale)
        #expect(direct("[::ffff:8.8.8.8]:58465") == .internet)
    }

    @Test func rfc1918EdgesAndPublicAddresses() {
        #expect(direct("10.0.0.1:1") == .lan)
        #expect(direct("172.16.0.1:1") == .lan)
        #expect(direct("172.31.255.255:1") == .lan)
        #expect(direct("172.32.0.1:1") == .internet)
        #expect(direct("192.168.1.196:58465") == .lan)
        #expect(direct("127.0.0.1:58465") == .lan)
        #expect(direct("8.8.8.8:58465") == .internet)
        #expect(direct("[2001:db8::1]:58465") == .internet)
    }

    @Test func malformedAddressesAreInternetNotLAN() {
        for raw in ["", "garbage", "192.168.1.5", "192.168.1.5:0", "192.168.1.5:70000", "010.0.0.1:5", "[fe80::1:5", "fe80::1:5"] {
            #expect(direct(raw) == .internet, "\(raw)")
        }
        #expect(SupermuxSocketAddress("010.0.0.1:5") == nil)
        #expect(SupermuxSocketAddress("192.168.1.5") == nil)
    }

    @Test func socketAddressesKeepACanonicalSpelling() throws {
        #expect(try #require(SupermuxSocketAddress("[FE80::1%en0]:7")).description == "[fe80::1]:7")
        #expect(try #require(SupermuxSocketAddress("[::ffff:192.168.1.5]:7")).description == "192.168.1.5:7")
        #expect(try #require(SupermuxSocketAddress("192.168.1.5:58465")).description == "192.168.1.5:58465")
        #expect(try #require(SupermuxSocketAddress("[2001:DB8:0:0::1]:9")).description == "[2001:db8::1]:9")
    }

    // MARK: Relays

    @Test func relayURLSpellingsGiveOneID() {
        for url in [
            "https://apne1.relay.cmux.dev/", "https://apne1.relay.cmux.dev",
            "HTTPS://APNE1.relay.cmux.dev/", "https://apne1.relay.cmux.dev./", "apne1.relay.cmux.dev",
        ] {
            let route = SupermuxLinkRouteClassifier.classify(isRelay: true, remoteAddress: url, rttMs: 241, now: now)
            #expect(route.kind == .relay(id: "apne1"), "\(url)")
        }
    }

    @Test func relayPathWithoutURLStaysARelay() {
        let route = SupermuxLinkRouteClassifier.classify(isRelay: true, remoteAddress: "", rttMs: nil, now: now)
        #expect(route.isRelay)
        #expect(route.relayID == nil)
        #expect(route.relayPlace == nil)
    }

    @Test func confirmedRelayIDsNameTheirCity() {
        #expect(SupermuxRelayPlace(id: "apne1").displayName == "Tokyo")
        #expect(SupermuxRelayPlace(id: "apse1").displayName == "Singapore")
        #expect(SupermuxRelayPlace(id: "ape1").displayName == "Taiwan")
        #expect(SupermuxRelayPlace(id: "APNE1").confidence == .confirmed)
    }

    @Test func assumedRelayCitiesShowTheirRegion() {
        let usc1 = SupermuxRelayPlace(id: "usc1")
        #expect(usc1.confidence == .bestEffort)
        #expect(usc1.city == "Iowa")
        #expect(usc1.displayName == "US Central")
        #expect(SupermuxRelayPlace(id: "euw4").displayName == "Europe West")
    }

    @Test func unknownRelayIDShowsItself() {
        let place = SupermuxRelayPlace(id: "xyz9")
        #expect(place.confidence == .unknown)
        #expect(place.city == nil)
        #expect(place.displayName == "XYZ9")
    }

    // MARK: RTT

    @Test func rttIsKeptOrNil() {
        #expect(SupermuxLinkRouteClassifier.classify(isRelay: false, remoteAddress: "10.0.0.1:1", rttMs: nil, now: now).rttMs == nil)
        #expect(SupermuxLinkRouteClassifier.classify(isRelay: false, remoteAddress: "10.0.0.1:1", rttMs: 0, now: now).rttMs == 0)
        #expect(SupermuxLinkRouteClassifier.classify(isRelay: false, remoteAddress: "10.0.0.1:1", rttMs: .max, now: now).rttMs == Int.max)
    }

    // MARK: Publishing

    private func route(_ kind: SupermuxLinkRoute.Kind, _ rtt: Int?, at seconds: TimeInterval) -> SupermuxLinkRoute {
        SupermuxLinkRoute(kind: kind, rttMs: rtt, since: now.addingTimeInterval(seconds))
    }

    @Test func firstSampleIsPublishedAtOnce() {
        let sample = route(.direct(.lan), 6, at: 0)
        #expect(SupermuxLinkRoutePublishing.next(published: nil, publishedAt: nil, sample: sample, now: now) == sample)
    }

    @Test func rttJitterIsNotRepublished() {
        let published = route(.direct(.lan), 6, at: 0)
        let jitter = route(.direct(.lan), 8, at: 30)
        #expect(SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: now, sample: jitter, now: now.addingTimeInterval(30)) == nil)
        let relayJitter = route(.relay(id: "apne1"), 270, at: 30)
        #expect(SupermuxLinkRoutePublishing.next(
            published: route(.relay(id: "apne1"), 241, at: 0), publishedAt: now,
            sample: relayJitter, now: now.addingTimeInterval(30)) == nil)
    }

    @Test func kindChangeIsPublishedAtOnce() {
        let published = route(.relay(id: "apne1"), 241, at: 0)
        let direct = route(.direct(.tailscale), 8, at: 1)
        let next = SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: now, sample: direct, now: now.addingTimeInterval(1))
        #expect(next == direct)
        let otherRelay = route(.relay(id: "ape1"), 300, at: 1)
        #expect(SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: now, sample: otherRelay, now: now.addingTimeInterval(1)) == otherRelay)
    }

    @Test func largeRTTMoveWaitsForTheInterval() {
        let published = route(.direct(.lan), 6, at: 0)
        let moved = route(.direct(.lan), 40, at: 2)
        #expect(SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: now, sample: moved, now: now.addingTimeInterval(2)) == nil)
        let later = SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: now, sample: moved, now: now.addingTimeInterval(5))
        #expect(later?.rttMs == 40)
    }

    @Test func rttOnlyUpdateKeepsSince() {
        let published = route(.direct(.lan), 6, at: 0)
        let moved = route(.direct(.lan), 40, at: 60)
        let next = SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: now, sample: moved, now: now.addingTimeInterval(60))
        #expect(next?.since == published.since)
        #expect(next?.rttMs == 40)
    }

    @Test func firstRTTIsPublishedAtOnce() {
        let published = route(.direct(.lan), nil, at: 0)
        let measured = route(.direct(.lan), 6, at: 1)
        let next = SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: now, sample: measured, now: now.addingTimeInterval(1))
        #expect(next?.rttMs == 6)
        #expect(next?.since == published.since)
    }

    // MARK: Coding

    @Test func routeCodesFlat() throws {
        let route = SupermuxLinkRoute(kind: .relay(id: "apne1"), rttMs: 241, since: now)
        let data = try JSONEncoder().encode(route)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "relay")
        #expect(object["relay_id"] as? String == "apne1")
        #expect(object["rtt_ms"] as? Int == 241)
        #expect(try JSONDecoder().decode(SupermuxLinkRoute.self, from: data) == route)
        let lan = SupermuxLinkRoute(kind: .direct(.lan), rttMs: nil, since: now)
        #expect(try JSONDecoder().decode(SupermuxLinkRoute.self, from: JSONEncoder().encode(lan)) == lan)
    }
}

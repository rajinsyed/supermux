import Foundation
import Testing
@testable import SupermuxMobileCore

/// Which of a peer's direct addresses this device can reach, from its own
/// interfaces (review findings T2 and T13, written before the filter):
/// 1. A peer's address that is one of this device's own (a VM bridge such as
///    192.168.64.1 or 10.211.55.2 exists on both Macs) is dialed and reaches
///    this device's own host endpoint, failing the key check.
/// 2. A LAN address on a subnet this device is not on (the peer's home Wi-Fi
///    while this device is on cellular or a hotel's Wi-Fi) is dialed and
///    blackholes for the whole 1.5 s direct deadline on every dial.
/// 3. A cellular interface (point-to-point, often in 10/8 or the carrier's
///    100.64/10 CGNAT) passes for the LAN or for Tailscale.
/// 4. Tailscale addresses are dialed with no Tailscale interface up.
/// 5. Global IPv6 is dialed from a device with no global IPv6 of its own.
/// 6. A global IPv6 path inside this device's own /64 (both Macs at home)
///    shows as "Direct · Internet".
/// 7. Reading the interfaces returns loopback, or a prefix out of range.
///
/// Second review (2026-10-06), written before the fixes:
/// 8. (#7) The filter drops paths that work: a LAN address on a routed second
///    subnet of the same home network, a peer reached over WireGuard on a
///    point-to-point `utun`, a LAN address behind Tailscale's subnet routes.
///    A private address is worth a try whenever this device is on a private
///    network of that family (Wi-Fi, wired or a tunnel, never cellular), or
///    Tailscale is up; with cellular alone it is still left out.
/// 9. (#7) The user's own Private Addresses are filtered like learned ones;
///    only "never this device's own address" applies to them.
/// 10. (#1) A foreground reads as a network change: the interfaces' full
///    address set changes with link-local addresses (fe80::/10 on `awdl0`
///    and `llw0`), interfaces that come and go on their own (`ipsec`,
///    `anpi`) and rotating temporary IPv6 addresses. The fingerprint keeps
///    only what names the network.
@Suite struct SupermuxRouteReachabilityTests {
    private func interface(_ name: String, _ address: String, _ prefix: Int, p2p: Bool = false) -> SupermuxLocalInterface {
        SupermuxLocalInterface(name: name, address: address, prefixLength: prefix, isPointToPoint: p2p)!
    }

    private var homeMac: [SupermuxLocalInterface] {
        [
            interface("en0", "192.168.1.20", 24),
            interface("en0", "2001:db8:1:2::20", 64),
            interface("bridge100", "192.168.64.1", 24),
            interface("utun4", "100.101.102.103", 32, p2p: true),
            interface("utun4", "fd7a:115c:a1e0::1234", 128, p2p: true),
        ]
    }

    @Test("1. a peer's address that is this device's own is never dialed")
    func ownAddressesAreDropped() {
        let reachable = SupermuxRouteCandidates.reachable(
            ["192.168.64.1:58465", "192.168.1.5:58465", "100.101.102.103:58465"], from: homeMac)
        #expect(reachable == ["192.168.1.5:58465"])
    }

    @Test("2 and 3. LAN only from a private network of its family; never from cellular alone")
    func lanNeedsAPrivateNetwork() {
        let peer = ["192.168.1.5:58465", "10.0.0.9:58465", "[fd12:3456:789a:1::5]:58465"]
        let wifi = [interface("en0", "192.168.1.20", 24), interface("en0", "2001:db8:1:2::20", 64)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: wifi) == ["192.168.1.5:58465", "10.0.0.9:58465"],
                "no private IPv6 here: the ULA is left out")
        let office = [interface("en0", "10.0.0.7", 24), interface("en0", "fd12:3456:789a:1::7", 64)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: office)
                == ["10.0.0.9:58465", "[fd12:3456:789a:1::5]:58465", "192.168.1.5:58465"],
                "this device's own subnets first: the dial's cap keeps them")
        let cellular = [interface("pdp_ip0", "10.0.0.3", 8, p2p: true), interface("pdp_ip0", "2600:380:1:2::9", 64, p2p: true)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: cellular).isEmpty, "a cellular link is not a LAN")
        let linkLocalOnly = [interface("en0", "169.254.7.7", 16), interface("en0", "fe80::1", 64)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: linkLocalOnly).isEmpty, "a self-assigned address is no network")
    }

    @Test("3 and 4. Tailscale only with a Tailscale interface up")
    func tailscaleNeedsItsInterface() {
        let peer = ["100.69.64.102:58465", "[fd7a:115c:a1e0::99]:58465"]
        #expect(SupermuxRouteCandidates.reachable(peer, from: homeMac) == peer)
        let noTailscale = [interface("en0", "192.168.1.20", 24)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: noTailscale).isEmpty)
        let carrierCGNAT = [interface("pdp_ip0", "100.70.1.2", 32, p2p: true)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: carrierCGNAT).isEmpty,
                "a carrier's 100.64/10 address is not Tailscale")
    }

    @Test("5. global IPv6 only from a device with a global IPv6 address")
    func globalIPv6NeedsGlobalIPv6() {
        let peer = ["[2001:db8:9:9::5]:58465"]
        #expect(SupermuxRouteCandidates.reachable(peer, from: homeMac) == peer)
        #expect(SupermuxRouteCandidates.reachable(peer, from: [interface("en0", "192.168.1.20", 24)]).isEmpty)
        let cellular = [interface("pdp_ip0", "2600:380:1:2::9", 64, p2p: true)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: cellular) == peer)
    }

    @Test("6. a global IPv6 path inside this device's /64 is the LAN")
    func sameSlash64IsLAN() {
        let home = SupermuxLinkRouteClassifier.classify(
            isRelay: false, remoteAddress: "[2001:db8:1:2::5]:58465", rttMs: 4, now: Date(), localInterfaces: homeMac)
        #expect(home.kind == .direct(.lan))
        let away = SupermuxLinkRouteClassifier.classify(
            isRelay: false, remoteAddress: "[2001:db8:9:9::5]:58465", rttMs: 40, now: Date(), localInterfaces: homeMac)
        #expect(away.kind == .direct(.internet))
        let unknown = SupermuxLinkRouteClassifier.classify(
            isRelay: false, remoteAddress: "[2001:db8:1:2::5]:58465", rttMs: 4, now: Date())
        #expect(unknown.kind == .direct(.internet), "without interfaces nothing changes")
    }

    @Test("7. this device's interfaces: no loopback, prefixes in range")
    func currentInterfaces() {
        let interfaces = SupermuxLocalInterface.current()
        print("this device's interfaces: \(interfaces)")
        #expect(!interfaces.isEmpty, "a test machine has at least one network address")
        for entry in interfaces {
            #expect(!entry.address.hasPrefix("127.") && entry.address != "::1", "\(entry)")
            #expect((0...128).contains(entry.prefixLength), "\(entry)")
        }
        #expect(SupermuxLocalInterface(name: "en0", address: "not-an-address", prefixLength: 24, isPointToPoint: false) == nil)
    }

    @Test("8. a routed second subnet, WireGuard on a point-to-point utun, Tailscale's subnet routes")
    func privatePathsBeyondTheSubnet() {
        let secondSubnet = [interface("en0", "192.168.1.20", 24)]
        #expect(SupermuxRouteCandidates.reachable(["192.168.2.5:58465"], from: secondSubnet) == ["192.168.2.5:58465"])
        let wireGuard = [interface("pdp_ip0", "10.120.3.4", 32, p2p: true), interface("utun6", "10.8.0.2", 32, p2p: true)]
        #expect(SupermuxRouteCandidates.reachable(["10.8.0.1:58465"], from: wireGuard) == ["10.8.0.1:58465"])
        let tailscaleOnCellular = [interface("pdp_ip0", "10.120.3.4", 32, p2p: true),
                                   interface("utun4", "100.101.102.103", 32, p2p: true)]
        #expect(SupermuxRouteCandidates.reachable(["192.168.1.5:58465", "[fd12::5]:58465"], from: tailscaleOnCellular)
                == ["192.168.1.5:58465", "[fd12::5]:58465"])
    }

    @Test("9. the user's Private Addresses: only never this device's own")
    func privateAddressesKeepAllButOwn() {
        let cellular = [interface("pdp_ip0", "10.0.0.3", 8, p2p: true)]
        let typed = ["192.168.1.5:58465", "10.0.0.3:58465", "203.0.113.9:58465", "garbage"]
        #expect(SupermuxRouteCandidates.excludingOwn(typed, from: cellular) == ["192.168.1.5:58465", "203.0.113.9:58465"])
    }

    @Test("10. the network fingerprint: link-local, transient interfaces and temporary IPv6 leave it alone")
    func networkFingerprint() {
        let home = [
            interface("en0", "192.168.1.20", 24),
            interface("en0", "2001:db8:1:2:aaaa:bbbb:cccc:1", 64),
            interface("en0", "fe80::1", 64),
            interface("utun4", "100.101.102.103", 32, p2p: true),
        ]
        let foreground = [
            interface("en0", "192.168.1.20", 24),
            interface("en0", "2001:db8:1:2:1111:2222:3333:4", 64),
            interface("en0", "fe80::1", 64),
            interface("awdl0", "fe80::99", 64),
            interface("llw0", "fe80::98", 64),
            interface("ipsec0", "2001:db8:ffff::1", 64),
            interface("anpi0", "fe80::7", 64),
            interface("utun0", "fe80::abcd", 64, p2p: true),
            interface("utun4", "100.101.102.103", 32, p2p: true),
        ]
        #expect(SupermuxLocalInterface.networkFingerprint(home) == SupermuxLocalInterface.networkFingerprint(foreground))
        let newWiFi = [interface("en0", "192.168.7.20", 24), interface("utun4", "100.101.102.103", 32, p2p: true)]
        #expect(SupermuxLocalInterface.networkFingerprint(home) != SupermuxLocalInterface.networkFingerprint(newWiFi))
        let renumbered = home.map { $0.name == "en0" && $0.address.hasPrefix("2001")
            ? interface("en0", "2001:db8:1:9::1", 64) : $0 }
        #expect(SupermuxLocalInterface.networkFingerprint(home) != SupermuxLocalInterface.networkFingerprint(renumbered),
                "a new /64 is a new network")
        let cellular = [interface("pdp_ip0", "10.0.0.3", 8, p2p: true)]
        #expect(SupermuxLocalInterface.networkFingerprint(home) != SupermuxLocalInterface.networkFingerprint(cellular))
    }
}

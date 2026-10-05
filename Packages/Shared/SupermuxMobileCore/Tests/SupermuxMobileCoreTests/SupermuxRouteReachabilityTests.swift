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

    @Test("2 and 3. LAN only on a Wi-Fi or wired subnet this device is on")
    func lanNeedsASharedSubnet() {
        let peer = ["192.168.1.5:58465", "10.0.0.9:58465", "[fd12:3456:789a:1::5]:58465"]
        #expect(SupermuxRouteCandidates.reachable(peer, from: homeMac) == ["192.168.1.5:58465"])
        let office = [interface("en0", "10.0.0.7", 24), interface("en0", "fd12:3456:789a:1::7", 64)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: office) == ["10.0.0.9:58465", "[fd12:3456:789a:1::5]:58465"])
        let cellular = [interface("pdp_ip0", "10.0.0.3", 8, p2p: true)]
        #expect(SupermuxRouteCandidates.reachable(peer, from: cellular).isEmpty, "a cellular link is not a LAN")
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
        #expect(!interfaces.isEmpty, "a test machine has at least one network address")
        for entry in interfaces {
            #expect(!entry.address.hasPrefix("127.") && entry.address != "::1", "\(entry)")
            #expect((0...128).contains(entry.prefixLength), "\(entry)")
        }
        #expect(SupermuxLocalInterface(name: "en0", address: "not-an-address", prefixLength: 24, isPointToPoint: false) == nil)
    }
}

import CMUXMobileCore
import Darwin
import Foundation

/// One address on one of this device's network interfaces: what decides
/// which of a peer's direct addresses this device can reach
/// (``SupermuxRouteCandidates/reachable(_:from:)``) and whether a direct path
/// stays inside the home network (``SupermuxLinkRouteClassifier``).
public struct SupermuxLocalInterface: Hashable, Sendable, CustomStringConvertible {
    /// The interface's BSD name (`en0`, `utun4`, `pdp_ip0`, `bridge100`).
    public let name: String
    /// The canonical numeric address, without a zone.
    public let address: String
    /// The subnet's prefix length.
    public let prefixLength: Int
    /// A point-to-point link: a VPN tunnel (`utun`) or cellular (`pdp_ip`),
    /// never a LAN, whatever its address range.
    public let isPointToPoint: Bool
    let family: SupermuxSocketAddress.Family
    let bytes: [UInt8]

    /// Nil for an address that does not parse or a prefix out of range.
    /// - Parameters:
    ///   - name: The interface's BSD name.
    ///   - address: An IPv4 or IPv6 literal (a zone is dropped).
    ///   - prefixLength: The subnet's prefix length.
    ///   - isPointToPoint: Whether the interface is point-to-point.
    public init?(name: String, address: String, prefixLength: Int, isPointToPoint: Bool) {
        let spelled = address.contains(":") ? "[\(address)]:1" : "\(address):1"
        guard let parsed = SupermuxSocketAddress(spelled),
              (0...(parsed.family == .ipv4 ? 32 : 128)).contains(prefixLength) else { return nil }
        self.name = name
        self.address = parsed.host
        self.prefixLength = prefixLength
        self.isPointToPoint = isPointToPoint
        family = parsed.family
        bytes = parsed.bytes
    }

    public var description: String {
        "\(name) \(address)/\(prefixLength)\(isPointToPoint ? " p2p" : "")"
    }

    /// Whether `other` is inside this interface's subnet.
    func contains(_ other: SupermuxSocketAddress) -> Bool {
        guard other.family == family, prefixLength > 0 else { return false }
        let fullBytes = prefixLength / 8
        guard bytes.prefix(fullBytes) == other.bytes.prefix(fullBytes) else { return false }
        let remainingBits = prefixLength % 8
        guard remainingBits > 0 else { return true }
        let mask = UInt8(0xFF) << (8 - remainingBits)
        return bytes[fullBytes] & mask == other.bytes[fullBytes] & mask
    }

    /// Tailscale's tunnel: a `utun` with an address in Tailscale's ranges (a
    /// cellular interface can hold a carrier's 100.64/10 address too).
    var isTailscale: Bool {
        name.hasPrefix("utun") && CmxTailscalePeerAddress(address) != nil
    }

    /// A global unicast IPv6 address (`2000::/3`).
    var isGlobalIPv6: Bool {
        family == .ipv6 && (bytes[0] & 0xE0) == 0x20
    }

    /// This device's addresses now: every IPv4 and IPv6 address of an
    /// interface that is up and running, loopback left out.
    public static func current() -> [SupermuxLocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [SupermuxLocalInterface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let socketAddress = entry.ifa_addr, let host = numericHost(socketAddress) else { continue }
            let name = String(cString: entry.ifa_name)
            let pointToPoint = flags & IFF_POINTOPOINT != 0 || name.hasPrefix("pdp_ip")
            let prefix = entry.ifa_netmask.map(prefixLength) ?? 0
            if let interface = SupermuxLocalInterface(
                name: name, address: host, prefixLength: prefix, isPointToPoint: pointToPoint) {
                result.append(interface)
            }
        }
        return result
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The number of leading one bits in a netmask.
    private static func prefixLength(_ netmask: UnsafeMutablePointer<sockaddr>) -> Int {
        let bytes: [UInt8]
        switch Int32(netmask.pointee.sa_family) {
        case AF_INET6:
            bytes = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
        default:
            // An IPv4 netmask may come with family 0 and a short length; its bytes sit where sin_addr does.
            bytes = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
            }
        }
        var count = 0
        for byte in bytes {
            guard byte == 0xFF else {
                count += (~byte).leadingZeroBitCount
                break
            }
            count += 8
        }
        return count
    }
}

extension SupermuxRouteCandidates {
    /// The addresses among a peer's that this device can reach directly,
    /// judged from its own interfaces, in their order:
    /// - never one of this device's own addresses (a VM bridge address both
    ///   Macs have would reach this device's own host);
    /// - LAN (private IPv4, ULA) only when a Wi-Fi or wired interface (not
    ///   point-to-point) is on that subnet;
    /// - Tailscale only when Tailscale's tunnel is up here;
    /// - global IPv6 only when this device has a global IPv6 address.
    ///
    /// Anything else (public IPv4, unparsable) is left out. A dial with
    /// nothing left skips the direct lane instead of waiting out its deadline.
    /// - Parameters:
    ///   - addresses: The peer's direct addresses.
    ///   - interfaces: This device's (``SupermuxLocalInterface/current()``).
    /// - Returns: The ones worth dialing.
    public static func reachable(_ addresses: [String], from interfaces: [SupermuxLocalInterface]) -> [String] {
        let hasTailscale = interfaces.contains { $0.isTailscale }
        let hasGlobalIPv6 = interfaces.contains { $0.isGlobalIPv6 }
        return addresses.filter { raw in
            guard let address = SupermuxSocketAddress(raw),
                  !interfaces.contains(where: { $0.bytes == address.bytes }) else { return false }
            switch address.routeScope {
            case .tailscale: return hasTailscale
            case .lan: return interfaces.contains { !$0.isPointToPoint && $0.contains(address) }
            case .internet: return address.isGlobalIPv6 && hasGlobalIPv6
            }
        }
    }
}

extension SupermuxSocketAddress {
    /// Where a direct path to this address goes, from a device with
    /// `interfaces`: a global IPv6 address inside a Wi-Fi or wired subnet of
    /// this device (both Macs at home) is the LAN.
    func routeScope(from interfaces: [SupermuxLocalInterface]) -> SupermuxLinkRoute.Scope {
        let scope = routeScope
        guard scope == .internet, isGlobalIPv6,
              interfaces.contains(where: { !$0.isPointToPoint && $0.contains(self) }) else { return scope }
        return .lan
    }
}

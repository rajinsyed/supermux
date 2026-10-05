import CMUXMobileCore
import Darwin
import Foundation

/// A numeric socket address as iroh writes one (`192.168.1.5:58465`,
/// `[fe80::1%14]:58465`), parsed and respelled canonically.
///
/// The zone of a link-local IPv6 address is dropped: it names an interface on
/// the machine that wrote it. An IPv4-mapped IPv6 address becomes its IPv4
/// address. ``description`` is the spelling Rust's `SocketAddr` parses, so a
/// value can go straight into an iroh `EndpointAddr`.
public struct SupermuxSocketAddress: Hashable, Sendable, CustomStringConvertible {
    /// The address family.
    public enum Family: Hashable, Sendable {
        case ipv4, ipv6
    }

    /// The canonical numeric host, without brackets or zone.
    public let host: String
    /// The UDP port, never 0.
    public let port: UInt16
    /// The address family.
    public let family: Family
    private let bytes: [UInt8]

    /// Parses `a.b.c.d:port` or `[v6]:port` (with an optional `%zone`).
    /// Returns nil for anything else, a port of 0 and a non-canonical IPv4
    /// spelling (`010.0.0.1`, which Rust's parser refuses).
    public init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPart: Substring
        let portPart: Substring
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"),
                  value[value.index(after: close)...].hasPrefix(":") else { return nil }
            hostPart = value[value.index(after: value.startIndex)..<close]
            portPart = value[value.index(close, offsetBy: 2)...]
        } else {
            guard let colon = value.lastIndex(of: ":") else { return nil }
            hostPart = value[..<colon]
            portPart = value[value.index(after: colon)...]
            guard !hostPart.contains(":") else { return nil }
        }
        guard let port = UInt16(portPart), port != 0 else { return nil }
        let unzoned = String(hostPart.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard let parsed = Self.parseHost(unzoned, bracketed: value.hasPrefix("[")) else { return nil }
        host = parsed.canonical
        family = parsed.family
        bytes = parsed.bytes
        self.port = port
    }

    /// `host:port`, or `[host]:port` for IPv6.
    public var description: String {
        family == .ipv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Where a direct path to this address goes. Tailscale is checked first:
    /// its ranges overlap CGNAT and the IPv6 ULA block.
    public var routeScope: SupermuxLinkRoute.Scope {
        if CmxTailscalePeerAddress(host) != nil { return .tailscale }
        return isLocalNetwork ? .lan : .internet
    }

    /// Private, link-local or loopback.
    private var isLocalNetwork: Bool {
        switch family {
        case .ipv4:
            return bytes[0] == 10
                || (bytes[0] == 172 && (bytes[1] & 0xF0) == 16)
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
                || bytes[0] == 127
        case .ipv6:
            return (bytes[0] & 0xFE) == 0xFC || isIPv6LinkLocal || isIPv6Loopback
        }
    }

    /// Whether another machine can send to this address: not loopback,
    /// unspecified, link-local (its zone named the writer's interface),
    /// multicast, broadcast or reserved.
    public var isDialable: Bool {
        switch family {
        case .ipv4:
            return bytes[0] != 0 && bytes[0] != 127 && !(bytes[0] == 169 && bytes[1] == 254) && bytes[0] < 224
        case .ipv6:
            return !isIPv6Loopback && !isIPv6Unspecified && !isIPv6LinkLocal && bytes[0] != 0xFF
        }
    }

    /// Whether this is a global unicast IPv6 address (`2000::/3`).
    public var isGlobalIPv6: Bool {
        family == .ipv6 && (bytes[0] & 0xE0) == 0x20
    }

    private var isIPv6LinkLocal: Bool { bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 }
    private var isIPv6Loopback: Bool { bytes == [UInt8](repeating: 0, count: 15) + [1] }
    private var isIPv6Unspecified: Bool { bytes.allSatisfy { $0 == 0 } }

    // MARK: - Parsing

    private static func parseHost(
        _ value: String, bracketed: Bool
    ) -> (canonical: String, family: Family, bytes: [UInt8])? {
        if !bracketed, let v4 = parseIPv4(value) { return (v4.canonical, .ipv4, v4.bytes) }
        guard bracketed else { return nil }
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        if bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] {
            let v4 = Array(bytes.suffix(4))
            return (v4.map(String.init).joined(separator: "."), .ipv4, v4)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return (decode(buffer).lowercased(), .ipv6, bytes)
    }

    private static func parseIPv4(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let canonical = bytes.map(String.init).joined(separator: ".")
        // Darwin reads `010` as decimal; Rust and the dialer refuse it.
        return canonical == value ? (canonical, bytes) : nil
    }

    private static func decode(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

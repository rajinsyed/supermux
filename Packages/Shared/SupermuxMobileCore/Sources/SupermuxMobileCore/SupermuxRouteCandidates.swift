import Foundation

/// The direct addresses one Mac hands another over their authenticated link
/// (`mobile.supermux.route.candidates`), so the other can dial it directly
/// from the first packet instead of always starting on a relay.
///
/// Only addresses another of the user's devices can dial cold are served:
/// LAN (private IPv4 and ULA IPv6), Tailscale, and global IPv6. Loopback,
/// unspecified, link-local, multicast and public IPv4 (a NAT mapping a cold
/// dial cannot use) are left out. The receiver filters again with the same
/// rule: nothing a peer sends reaches iroh unchecked.
public enum SupermuxRouteCandidates {
    /// The most addresses served, kept or dialed per peer.
    public static let limit = 16

    /// The servable addresses among `addresses`, respelled canonically,
    /// without duplicates, LAN first, then Tailscale, then global IPv6, at
    /// most ``limit``.
    /// - Parameter addresses: Socket addresses as iroh lists them.
    /// - Returns: The addresses to hand over (or keep from a fetch).
    public static func servable(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        let parsed = addresses.compactMap(SupermuxSocketAddress.init).filter { address in
            address.isDialable && rank(address) != nil && seen.insert(address.description).inserted
        }
        let ordered = parsed.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element) ?? 0
            let right = rank(rhs.element) ?? 0
            return left != right ? left < right : lhs.offset < rhs.offset
        }
        return ordered.prefix(limit).map(\.element.description)
    }

    /// LAN 0, Tailscale 1, global IPv6 2; nil for an address not served.
    private static func rank(_ address: SupermuxSocketAddress) -> Int? {
        switch address.routeScope {
        case .lan: 0
        case .tailscale: 1
        case .internet: address.isGlobalIPv6 ? 2 : nil
        }
    }
}

/// The result of `mobile.supermux.route.candidates`: the answering Mac's
/// endpoint id and its servable direct addresses (``SupermuxRouteCandidates``).
public struct SupermuxRouteCandidatesDTO: Codable, Sendable, Equatable {
    /// The answering Mac's iroh endpoint id (hex), nil when it has none.
    public let endpointID: String?
    /// Its direct addresses, `ip:port` / `[v6]:port`.
    public let addresses: [String]

    /// Creates a result.
    /// - Parameters:
    ///   - endpointID: The endpoint id the addresses belong to.
    ///   - addresses: The direct addresses.
    public init(endpointID: String?, addresses: [String]) {
        self.endpointID = endpointID
        self.addresses = addresses
    }

    private enum CodingKeys: String, CodingKey {
        case endpointID = "endpoint_id"
        case addresses
    }
}

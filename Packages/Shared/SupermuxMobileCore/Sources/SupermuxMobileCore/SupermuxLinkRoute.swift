import Foundation

/// The path a live device link uses right now: direct (on the LAN, over
/// Tailscale or across the Internet) or through a relay, with the round trip
/// iroh measured on it.
///
/// Built by ``SupermuxLinkRouteClassifier`` from the connection's selected
/// path; published (throttled) through ``SupermuxLinkRoutePublishing``. UI
/// renders it as `Direct · LAN · 6 ms` or `Relay · Tokyo · 241 ms`; the
/// localized words belong to the UI layer, not to this model.
public struct SupermuxLinkRoute: Equatable, Sendable {
    /// Where a direct path goes.
    public enum Scope: String, Equatable, Sendable, Codable, CaseIterable {
        /// A private or link-local network address (RFC 1918, `169.254/16`,
        /// `fc00::/7` other than Tailscale's, `fe80::/10`, loopback).
        case lan
        /// A Tailscale peer address (`100.64/10`, `fd7a:115c:a1e0::/48`).
        case tailscale
        /// Any other address.
        case internet
    }

    /// Direct or relayed.
    public enum Kind: Equatable, Sendable {
        /// A direct UDP path to the peer.
        case direct(Scope)
        /// Through a relay; `id` is its host's first label (`apne1`), nil when
        /// the path carried no relay URL.
        case relay(id: String?)
    }

    /// Direct or relayed, and where.
    public var kind: Kind
    /// QUIC's smoothed round trip on the selected path, in milliseconds; nil
    /// before iroh measured one.
    public var rttMs: Int?
    /// When the link started using this kind of path (not reset by RTT updates).
    public var since: Date

    /// Creates a route.
    /// - Parameters:
    ///   - kind: Direct or relayed, and where.
    ///   - rttMs: The path's round trip in milliseconds, if measured.
    ///   - since: When the link started using this kind of path.
    public init(kind: Kind, rttMs: Int?, since: Date) {
        self.kind = kind
        self.rttMs = rttMs
        self.since = since
    }

    /// Whether the link goes through a relay.
    public var isRelay: Bool {
        if case .relay = kind { return true }
        return false
    }

    /// The direct path's scope; nil when relayed.
    public var scope: Scope? {
        if case let .direct(scope) = kind { return scope }
        return nil
    }

    /// The relay's id (`apne1`); nil when direct or unknown.
    public var relayID: String? {
        if case let .relay(id) = kind { return id }
        return nil
    }

    /// Where the relay is; nil when direct or the relay is unknown.
    public var relayPlace: SupermuxRelayPlace? {
        relayID.map(SupermuxRelayPlace.init(id:))
    }
}

extension SupermuxLinkRoute: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case scope
        case relayID = "relay_id"
        case rttMs = "rtt_ms"
        case since
    }

    /// Decodes the flat shape ``encode(to:)`` writes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "relay":
            kind = .relay(id: try container.decodeIfPresent(String.self, forKey: .relayID))
        case "direct":
            kind = .direct(try container.decode(Scope.self, forKey: .scope))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown route kind")
        }
        rttMs = try container.decodeIfPresent(Int.self, forKey: .rttMs)
        since = try container.decode(Date.self, forKey: .since)
    }

    /// Writes `{kind: "direct"|"relay", scope?, relay_id?, rtt_ms?, since}`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case let .direct(scope):
            try container.encode("direct", forKey: .kind)
            try container.encode(scope, forKey: .scope)
        case let .relay(id):
            try container.encode("relay", forKey: .kind)
            try container.encodeIfPresent(id, forKey: .relayID)
        }
        try container.encodeIfPresent(rttMs, forKey: .rttMs)
        try container.encode(since, forKey: .since)
    }
}

import Foundation

/// Turns a connection's selected path into a ``SupermuxLinkRoute``.
///
/// iroh reports a path as relay or IP with its remote address: the relay URL
/// (`https://apne1.relay.cmux.dev/`) or the socket address (`192.168.1.5:58465`).
/// A direct path is Tailscale, LAN or Internet by its address
/// (``SupermuxSocketAddress/routeScope``); one that does not parse counts as
/// Internet, never LAN. A relay is named by its host's first label.
public enum SupermuxLinkRouteClassifier {
    /// Classifies one selected path.
    /// - Parameters:
    ///   - isRelay: Whether the path goes through a relay.
    ///   - remoteAddress: The relay URL, or the peer's socket address.
    ///   - rttMs: iroh's round trip on the path, in milliseconds.
    ///   - now: The route's start, should it be a new kind.
    /// - Returns: The route.
    public static func classify(isRelay: Bool, remoteAddress: String, rttMs: UInt64?, now: Date) -> SupermuxLinkRoute {
        let kind: SupermuxLinkRoute.Kind = isRelay
            ? .relay(id: relayID(fromURL: remoteAddress))
            : .direct(SupermuxSocketAddress(remoteAddress)?.routeScope ?? .internet)
        return SupermuxLinkRoute(kind: kind, rttMs: rttMs.map { Int(clamping: $0) }, since: now)
    }

    /// The relay id in a relay URL: its host's first label, lower-cased
    /// (`https://APNE1.relay.cmux.dev./` is `apne1`). A bare host works too.
    /// - Parameter url: The relay URL.
    /// - Returns: The id, or nil when the URL names no host.
    public static func relayID(fromURL url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URLComponents(string: trimmed)?.host
            ?? trimmed.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
        guard let label = host?.split(separator: ".").first, !label.isEmpty else { return nil }
        return label.lowercased()
    }
}

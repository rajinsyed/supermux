import Foundation

/// A numeric `ip:port` (`[v6]:port`) socket address, parsed and respelled
/// canonically. Stub until the classifier lands.
public struct SupermuxSocketAddress: Hashable, Sendable, CustomStringConvertible {
    public enum Family: Hashable, Sendable { case ipv4, ipv6 }
    public let host: String
    public let port: UInt16
    public let family: Family

    public init?(_ rawValue: String) { return nil }

    public var description: String { "\(host):\(port)" }
    public var routeScope: SupermuxLinkRoute.Scope { .internet }
}

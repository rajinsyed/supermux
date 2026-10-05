import Foundation

/// Red stub (review T2/T13): not implemented yet.
public struct SupermuxLocalInterface: Hashable, Sendable {
    public let name: String
    public let address: String
    public let prefixLength: Int
    public let isPointToPoint: Bool

    public init?(name: String, address: String, prefixLength: Int, isPointToPoint: Bool) {
        self.name = name
        self.address = address
        self.prefixLength = prefixLength
        self.isPointToPoint = isPointToPoint
    }

    public static func current() -> [SupermuxLocalInterface] { [] }
}

extension SupermuxRouteCandidates {
    public static func reachable(_ addresses: [String], from interfaces: [SupermuxLocalInterface]) -> [String] {
        addresses
    }
}

extension SupermuxLinkRouteClassifier {
    public static func classify(
        isRelay: Bool, remoteAddress: String, rttMs: UInt64?, now: Date, localInterfaces: [SupermuxLocalInterface]
    ) -> SupermuxLinkRoute {
        classify(isRelay: isRelay, remoteAddress: remoteAddress, rttMs: rttMs, now: now)
    }
}

import Foundation

/// Stub until the exchange lands.
public enum SupermuxRouteCandidates {
    public static let limit = 16
    public static func servable(_ addresses: [String]) -> [String] { addresses }
}

/// Stub until the exchange lands.
public struct SupermuxRouteCandidatesDTO: Codable, Sendable, Equatable {
    public let endpointID: String?
    public let addresses: [String]
    public init(endpointID: String?, addresses: [String]) {
        self.endpointID = endpointID
        self.addresses = addresses
    }
}

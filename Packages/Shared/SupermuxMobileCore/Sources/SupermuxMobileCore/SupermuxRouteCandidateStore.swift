import Foundation

/// Stub until the exchange lands.
public struct SupermuxRoutePeerKey: Hashable, Sendable, Codable {
    public let deviceID: String
    public let tag: String
    public let endpointID: String
    public init(deviceID: String, tag: String, endpointID: String) {
        self.deviceID = deviceID
        self.tag = tag
        self.endpointID = endpointID
    }
}

/// Stub until the exchange lands.
public actor SupermuxRouteCandidateStore {
    public struct Peer: Codable, Equatable, Sendable {
        public let key: SupermuxRoutePeerKey
    }

    public static let maximumPeers = 64
    public nonisolated let fileURL: URL?

    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
    }

    public func recordFetched(_ addresses: [String], for key: SupermuxRoutePeerKey) {}
    public func learn(_ address: String, for key: SupermuxRoutePeerKey) {}
    public func dialAddresses(for key: SupermuxRoutePeerKey) -> [String] { [] }
    public func peers() -> [Peer] { [] }
}

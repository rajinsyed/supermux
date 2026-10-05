/// The path the phone's live session to one Mac uses right now, as iroh
/// reports it: relay or direct, the relay URL or the Mac's socket address,
/// and iroh's round trip on it.
public struct SupermuxPhoneLinkPath: Equatable, Sendable {
    /// The Mac's device id.
    public let macDeviceID: String
    /// The Mac app's build tag, if any.
    public let instanceTag: String?
    /// Whether the selected path goes through a relay.
    public let isRelay: Bool
    /// The relay URL, or the Mac's `ip:port`.
    public let remoteAddress: String
    /// QUIC's smoothed round trip on the path, in milliseconds.
    public let rttMs: UInt64?

    /// Creates a path.
    /// - Parameters:
    ///   - macDeviceID: The Mac's device id.
    ///   - instanceTag: The Mac app's build tag.
    ///   - isRelay: Whether the path is relayed.
    ///   - remoteAddress: The relay URL or the Mac's socket address.
    ///   - rttMs: The round trip in milliseconds.
    public init(macDeviceID: String, instanceTag: String?, isRelay: Bool, remoteAddress: String, rttMs: UInt64?) {
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.isRelay = isRelay
        self.remoteAddress = remoteAddress
        self.rttMs = rttMs
    }
}

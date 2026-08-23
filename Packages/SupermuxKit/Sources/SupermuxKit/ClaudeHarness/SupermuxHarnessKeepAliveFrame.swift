/// A protocol keep-alive frame.
public struct SupermuxHarnessKeepAliveFrame: Sendable {
    /// The complete raw frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a keep-alive frame.
    ///
    /// - Parameter rawObject: The complete raw frame.
    public init(rawObject: SupermuxHarnessJSONObject) {
        self.rawObject = rawObject
    }
}

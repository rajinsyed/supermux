/// Cancellation of a pending CLI-issued control request.
public struct SupermuxHarnessControlCancelRequestFrame: Sendable {
    /// The cancelled request identifier.
    public let requestID: String
    /// The complete raw frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a control-request cancellation frame.
    ///
    /// - Parameters:
    ///   - requestID: The cancelled request identifier.
    ///   - rawObject: The complete raw frame.
    public init(requestID: String, rawObject: SupermuxHarnessJSONObject) {
        self.requestID = requestID
        self.rawObject = rawObject
    }
}

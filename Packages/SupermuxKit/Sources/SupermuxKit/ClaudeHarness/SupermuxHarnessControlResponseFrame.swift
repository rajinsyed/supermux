/// Control response subtypes handled by the harness.
public enum SupermuxHarnessControlResponseSubtype: String, Sendable {
    /// The control operation completed successfully.
    case success
    /// The control operation failed.
    case error
}

/// A response to a client-issued control request.
public struct SupermuxHarnessControlResponseFrame: Sendable {
    /// Whether the response represents success or failure.
    public let subtype: SupermuxHarnessControlResponseSubtype
    /// The echoed request identifier.
    public let requestID: String
    /// The nested success payload, when present.
    public let response: SupermuxHarnessJSONObject?
    /// The complete raw frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a control response frame.
    ///
    /// - Parameters:
    ///   - subtype: The response subtype.
    ///   - requestID: The echoed request identifier.
    ///   - response: The optional nested response payload.
    ///   - rawObject: The complete raw frame.
    public init(
        subtype: SupermuxHarnessControlResponseSubtype,
        requestID: String,
        response: SupermuxHarnessJSONObject?,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.subtype = subtype
        self.requestID = requestID
        self.response = response
        self.rawObject = rawObject
    }
}

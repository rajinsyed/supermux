import Foundation

/// A `control_response` line answering an outbound harness control.
///
/// The envelope is consistently
/// `{"type":"control_response","response":{"subtype":"success"|"error","request_id":...}}`
/// but the inner `response` payload is subtype-dependent and often absent:
/// `list_models` returns `response.models`, `interrupt` returns
/// `response.still_queued`, while `set_model`/thinking/effort/fast-mode
/// respond with no inner payload at all.
public struct ClaudeControlResponseEnvelope: Sendable, Equatable {
    public let requestID: String?
    public let subtype: String?
    /// The optional inner payload; `nil` when the CLI echoes nothing.
    public let payload: ClaudeJSONValue?
    /// The error description on `subtype == "error"` responses.
    public let errorMessage: String?
    public let raw: ClaudeJSONValue

    public var isSuccess: Bool { subtype == "success" }

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        let response = object["response"]?.objectValue ?? [:]
        self.requestID = response["request_id"]?.stringValue
        self.subtype = response["subtype"]?.stringValue
        self.payload = response["response"]
        self.errorMessage = response["error"]?.stringValue
        self.raw = raw
    }
}

/// One model descriptor from a `list_models` response.
///
/// Entries are heterogeneous: capability fields are optional and must not
/// default to true (Haiku had only identity fields; Fable omitted
/// `supportsFastMode`).
public struct ClaudeModelDescriptor: Sendable, Equatable {
    /// The string to send back through `set_model`.
    public let value: String
    /// The canonical resolution, possibly with a context suffix (`[1m]`).
    public let resolvedModel: String?
    public let displayName: String?
    public let description: String?
    public let supportsEffort: Bool?
    public let supportedEffortLevels: [String]
    public let supportsAdaptiveThinking: Bool?
    public let supportsFastMode: Bool?
    public let supportsAutoMode: Bool?
    public let raw: ClaudeJSONValue

    init?(value jsonValue: ClaudeJSONValue) {
        guard let object = jsonValue.objectValue,
              let value = object["value"]?.stringValue else { return nil }
        self.value = value
        self.resolvedModel = object["resolvedModel"]?.stringValue
        self.displayName = object["displayName"]?.stringValue
        self.description = object["description"]?.stringValue
        self.supportsEffort = object["supportsEffort"]?.boolValue
        self.supportedEffortLevels =
            object["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.supportsAdaptiveThinking = object["supportsAdaptiveThinking"]?.boolValue
        self.supportsFastMode = object["supportsFastMode"]?.boolValue
        self.supportsAutoMode = object["supportsAutoMode"]?.boolValue
        self.raw = jsonValue
    }

    /// Parses the `models` array of a `list_models` response payload.
    public static func models(from payload: ClaudeJSONValue?) -> [ClaudeModelDescriptor] {
        payload?["models"]?.arrayValue?.compactMap(ClaudeModelDescriptor.init(value:)) ?? []
    }
}

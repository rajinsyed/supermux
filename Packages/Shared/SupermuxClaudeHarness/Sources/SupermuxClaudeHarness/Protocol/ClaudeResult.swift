import Foundation

/// The authoritative terminal `result` line of one print-mode invocation.
///
/// Interrupt terminates as `subtype: "error_during_execution"` with
/// `terminal_reason: "aborted_streaming"` and `stop_reason: null`; a nonzero
/// process exit after a complete interrupt result is expected, not a protocol
/// failure. A denied tool permission leaves the overall result successful
/// (`terminal_reason: "completed"`) with the denial listed separately.
public struct ClaudeResult: Sendable, Equatable {
    public let subtype: String?
    public let isError: Bool?
    public let resultText: String?
    public let sessionID: String?
    public let uuid: String?
    public let durationMs: Int?
    public let durationAPIMs: Int?
    public let ttftMs: Int?
    public let ttftStreamMs: Int?
    public let timeToRequestMs: Int?
    public let numTurns: Int?
    public let stopReason: String?
    public let terminalReason: String?
    public let totalCostUSD: Double?
    public let usage: ClaudeUsage?
    /// Per-model usage keyed by the CLI-reported model name (camelCase wire).
    public let modelUsage: [String: ClaudeModelUsage]
    public let permissionDenials: ClaudeJSONValue?
    public let fastModeState: String?
    public let fastModeDisabledReason: String?
    public let apiErrorStatus: ClaudeJSONValue?
    public let errors: [String]
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.subtype = object["subtype"]?.stringValue
        self.isError = object["is_error"]?.boolValue
        self.resultText = object["result"]?.stringValue
        self.sessionID = object["session_id"]?.stringValue
        self.uuid = object["uuid"]?.stringValue
        self.durationMs = object["duration_ms"]?.intValue
        self.durationAPIMs = object["duration_api_ms"]?.intValue
        self.ttftMs = object["ttft_ms"]?.intValue
        self.ttftStreamMs = object["ttft_stream_ms"]?.intValue
        self.timeToRequestMs = object["time_to_request_ms"]?.intValue
        self.numTurns = object["num_turns"]?.intValue
        self.stopReason = object["stop_reason"]?.stringValue
        self.terminalReason = object["terminal_reason"]?.stringValue
        self.totalCostUSD = object["total_cost_usd"]?.numberValue
        self.usage = (object["usage"]?.objectValue).map {
            ClaudeUsage(object: $0, raw: object["usage"] ?? .null)
        }
        if let models = object["modelUsage"]?.objectValue {
            self.modelUsage = models.mapValues { value in
                ClaudeModelUsage(object: value.objectValue ?? [:], raw: value)
            }
        } else {
            self.modelUsage = [:]
        }
        self.permissionDenials = object["permission_denials"]
        self.fastModeState = object["fast_mode_state"]?.stringValue
        self.fastModeDisabledReason = object["fast_mode_disabled_reason"]?.stringValue
        self.apiErrorStatus = object["api_error_status"]
        self.errors = object["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.raw = raw
    }
}

/// Aggregate token usage (snake_case wire, used by `result.usage` and
/// message-level `usage`).
public struct ClaudeUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    /// The `cache_creation` breakdown object (ephemeral 5m/1h split).
    public let cacheCreation: ClaudeJSONValue?
    /// The `server_tool_use` counters (web search/fetch requests).
    public let serverToolUse: ClaudeJSONValue?
    /// `output_tokens_details` (e.g. `thinking_tokens`); absent for text-only turns.
    public let outputTokensDetails: ClaudeJSONValue?
    public let serviceTier: String?
    public let inferenceGeo: String?
    public let speed: String?
    public let iterations: ClaudeJSONValue?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.inputTokens = object["input_tokens"]?.intValue
        self.outputTokens = object["output_tokens"]?.intValue
        self.cacheCreationInputTokens = object["cache_creation_input_tokens"]?.intValue
        self.cacheReadInputTokens = object["cache_read_input_tokens"]?.intValue
        self.cacheCreation = object["cache_creation"]
        self.serverToolUse = object["server_tool_use"]
        self.outputTokensDetails = object["output_tokens_details"]
        self.serviceTier = object["service_tier"]?.stringValue
        self.inferenceGeo = object["inference_geo"]?.stringValue
        self.speed = object["speed"]?.stringValue
        self.iterations = object["iterations"]
        self.raw = raw
    }
}

/// One `result.modelUsage` entry (camelCase wire, unlike `result.usage`).
public struct ClaudeModelUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let webSearchRequests: Int?
    public let costUSD: Double?
    /// CLI-reported capability, not a constant (observed 64000 and 32000).
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let canonicalModel: String?
    public let provider: String?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.inputTokens = object["inputTokens"]?.intValue
        self.outputTokens = object["outputTokens"]?.intValue
        self.cacheReadInputTokens = object["cacheReadInputTokens"]?.intValue
        self.cacheCreationInputTokens = object["cacheCreationInputTokens"]?.intValue
        self.webSearchRequests = object["webSearchRequests"]?.intValue
        self.costUSD = object["costUSD"]?.numberValue
        self.contextWindow = object["contextWindow"]?.intValue
        self.maxOutputTokens = object["maxOutputTokens"]?.intValue
        self.canonicalModel = object["canonicalModel"]?.stringValue
        self.provider = object["provider"]?.stringValue
        self.raw = raw
    }
}

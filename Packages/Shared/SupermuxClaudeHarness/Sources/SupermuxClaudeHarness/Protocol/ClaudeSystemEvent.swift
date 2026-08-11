import Foundation

/// A top-level `system` line.
public enum ClaudeSystemEvent: Sendable, Equatable {
    case initialize(ClaudeSystemInitialization)
    case status(ClaudeSystemStatus)
    case hookStarted(ClaudeHookEvent)
    case hookResponse(ClaudeHookEvent)
    case hookProgress(ClaudeHookEvent)
    case permissionDenied(ClaudeJSONValue)
    case thinkingTokens(ClaudeThinkingTokens)
    case compactBoundary(ClaudeJSONValue)
    case notification(ClaudeSystemNotification)
    case unknown(subtype: String?, payload: ClaudeJSONValue)

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        switch object["subtype"]?.stringValue {
        case "init":
            self = .initialize(ClaudeSystemInitialization(object: object, raw: raw))
        case "status":
            self = .status(ClaudeSystemStatus(object: object, raw: raw))
        case "hook_started":
            self = .hookStarted(ClaudeHookEvent(object: object, raw: raw))
        case "hook_response":
            self = .hookResponse(ClaudeHookEvent(object: object, raw: raw))
        case "hook_progress":
            self = .hookProgress(ClaudeHookEvent(object: object, raw: raw))
        case "permission_denied":
            self = .permissionDenied(raw)
        case "thinking_tokens":
            self = .thinkingTokens(ClaudeThinkingTokens(object: object, raw: raw))
        case "compact_boundary":
            self = .compactBoundary(raw)
        case "notification":
            self = .notification(ClaudeSystemNotification(object: object, raw: raw))
        default:
            self = .unknown(subtype: object["subtype"]?.stringValue, payload: raw)
        }
    }

    /// The session ID stamped on the event, when present.
    public var sessionID: String? {
        switch self {
        case .initialize(let value): return value.sessionID
        case .status(let value): return value.sessionID
        case .hookStarted(let value), .hookResponse(let value), .hookProgress(let value):
            return value.sessionID
        case .thinkingTokens(let value): return value.sessionID
        case .notification(let value): return value.sessionID
        case .permissionDenied(let value), .compactBoundary(let value):
            return value["session_id"]?.stringValue
        case .unknown(_, let value):
            return value["session_id"]?.stringValue
        }
    }
}

/// The `system.init` line: lifecycle identity and session capabilities.
public struct ClaudeSystemInitialization: Sendable, Equatable {
    public let sessionID: String?
    public let cwd: String?
    public let model: String?
    public let permissionMode: String?
    public let tools: [String]
    public let slashCommands: [String]
    /// Small string array, e.g. `["interrupt_receipt_v1", ...]`. Preserve
    /// unknown strings; do not infer control support from this list alone.
    public let capabilities: [String]
    public let claudeCodeVersion: String?
    public let outputStyle: String?
    public let apiKeySource: String?
    public let mcpServers: ClaudeJSONValue?
    public let agents: [String]
    public let fastModeState: String?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.sessionID = object["session_id"]?.stringValue
        self.cwd = object["cwd"]?.stringValue
        self.model = object["model"]?.stringValue
        self.permissionMode = object["permissionMode"]?.stringValue
        self.tools = Self.strings(object["tools"])
        self.slashCommands = Self.strings(object["slash_commands"])
        self.capabilities = Self.strings(object["capabilities"])
        self.claudeCodeVersion = object["claude_code_version"]?.stringValue
        self.outputStyle = object["output_style"]?.stringValue
        self.apiKeySource = object["apiKeySource"]?.stringValue
        self.mcpServers = object["mcp_servers"]
        self.agents = Self.strings(object["agents"])
        self.fastModeState = object["fast_mode_state"]?.stringValue
        self.raw = raw
    }

    private static func strings(_ value: ClaudeJSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// A `system.status` line. `status` may be null while the line still carries
/// an option update such as `permissionMode`.
public struct ClaudeSystemStatus: Sendable, Equatable {
    public let status: String?
    public let permissionMode: String?
    public let sessionID: String?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.status = object["status"]?.stringValue
        self.permissionMode = object["permissionMode"]?.stringValue
        self.sessionID = object["session_id"]?.stringValue
        self.raw = raw
    }
}

/// A hook lifecycle line (`hook_started` / `hook_response` / `hook_progress`).
/// Multiple concurrent hooks per turn are normal.
public struct ClaudeHookEvent: Sendable, Equatable {
    public let hookID: String?
    public let hookName: String?
    public let hookEvent: String?
    public let stdout: String?
    public let stderr: String?
    public let exitCode: Int?
    public let outcome: String?
    public let sessionID: String?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.hookID = object["hook_id"]?.stringValue
        self.hookName = object["hook_name"]?.stringValue
        self.hookEvent = object["hook_event"]?.stringValue
        self.stdout = object["stdout"]?.stringValue
        self.stderr = object["stderr"]?.stringValue
        self.exitCode = object["exit_code"]?.intValue
        self.outcome = object["outcome"]?.stringValue
        self.sessionID = object["session_id"]?.stringValue
        self.raw = raw
    }
}

/// A `system.thinking_tokens` progress line.
public struct ClaudeThinkingTokens: Sendable, Equatable {
    public let estimatedTokens: Int?
    public let estimatedTokensDelta: Int?
    public let sessionID: String?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.estimatedTokens = object["estimated_tokens"]?.intValue
        self.estimatedTokensDelta = object["estimated_tokens_delta"]?.intValue
        self.sessionID = object["session_id"]?.stringValue
        self.raw = raw
    }
}

/// A `system.notification` line (e.g. fast-mode overage rejection).
public struct ClaudeSystemNotification: Sendable, Equatable {
    public let key: String?
    public let text: String?
    public let priority: String?
    public let color: String?
    public let sessionID: String?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.key = object["key"]?.stringValue
        self.text = object["text"]?.stringValue
        self.priority = object["priority"]?.stringValue
        self.color = object["color"]?.stringValue
        self.sessionID = object["session_id"]?.stringValue
        self.raw = raw
    }
}

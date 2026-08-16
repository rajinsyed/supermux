/// A successfully parsed stdout line and its optional recognized protocol interpretation.
public struct SupermuxHarnessDecodedLine: Sendable {
    /// The original line, including its newline when one was read from the process.
    public let rawLine: String
    /// The complete JSON object for pass-through to the web renderer.
    public let object: SupermuxHarnessJSONObject
    /// The typed interpretation, or `nil` for an unknown type or subtype.
    public let frame: SupermuxHarnessFrame?

    /// Creates a decoded stdout line.
    ///
    /// - Parameters:
    ///   - rawLine: The original process line.
    ///   - object: The complete parsed object.
    ///   - frame: The recognized typed interpretation.
    public init(rawLine: String, object: SupermuxHarnessJSONObject, frame: SupermuxHarnessFrame?) {
        self.rawLine = rawLine
        self.object = object
        self.frame = frame
    }
}

/// A recognized CLI-to-client Claude Code stream frame.
public enum SupermuxHarnessFrame: Sendable {
    /// A lifecycle, status, task, hook, or informational system frame.
    case system(SupermuxHarnessSystemFrame)
    /// A raw Anthropic streaming event wrapped by Claude Code.
    case streamEvent(SupermuxHarnessStreamEventFrame)
    /// A completed assistant content-block frame.
    case assistant(SupermuxHarnessAssistantFrame)
    /// A user echo or tool-result feedback frame.
    case user(SupermuxHarnessUserFrame)
    /// A completed turn result and usage summary.
    case result(SupermuxHarnessResultFrame)
    /// A CLI-issued control request such as `can_use_tool`.
    case controlRequest(SupermuxHarnessControlRequestFrame)
    /// A response to a client-issued control request.
    case controlResponse(SupermuxHarnessControlResponseFrame)
    /// Cancellation of a previously issued CLI control request.
    case controlCancelRequest(SupermuxHarnessControlCancelRequestFrame)
    /// A transport keep-alive frame with no semantic payload.
    case keepAlive(SupermuxHarnessKeepAliveFrame)

    /// Returns the complete raw object associated with the frame.
    public var rawObject: SupermuxHarnessJSONObject {
        switch self {
        case .system(let frame): frame.rawObject
        case .streamEvent(let frame): frame.rawObject
        case .assistant(let frame): frame.rawObject
        case .user(let frame): frame.rawObject
        case .result(let frame): frame.rawObject
        case .controlRequest(let frame): frame.rawObject
        case .controlResponse(let frame): frame.rawObject
        case .controlCancelRequest(let frame): frame.rawObject
        case .keepAlive(let frame): frame.rawObject
        }
    }
}

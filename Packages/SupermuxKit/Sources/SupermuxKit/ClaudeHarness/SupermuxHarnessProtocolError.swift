/// Errors raised while parsing or encoding Claude Code stream protocol JSON.
public enum SupermuxHarnessProtocolError: Error, Equatable, Sendable {
    /// The input is not valid UTF-8 JSON.
    case invalidJSON
    /// The JSON root is not an object.
    case expectedJSONObject
    /// A supplied Foundation value cannot be represented as JSON.
    case invalidJSONObject
}

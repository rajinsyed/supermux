/// Errors produced by persisted Claude session discovery.
public enum SupermuxHarnessSessionDiscoveryError: Error, Equatable, Sendable {
    /// The session identifier contains path components or unsupported characters.
    case invalidSessionID
    /// No matching session JSONL exists in either resolved or unresolved project directory.
    case sessionNotFound(String)
}

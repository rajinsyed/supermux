/// Failures produced while probing Claude Code's initialize catalog without starting a user turn.
public enum SupermuxHarnessModelCatalogProbeError: Error, Equatable, Sendable {
    /// The initialize response did not arrive before the probe deadline.
    case timedOut
    /// The process exited before returning a successful initialize response.
    case processExited(Int32)
    /// Claude Code returned an initialize control error.
    case initializeFailed(String?)
    /// The probe stream ended without a response or lifecycle event.
    case incomplete
}

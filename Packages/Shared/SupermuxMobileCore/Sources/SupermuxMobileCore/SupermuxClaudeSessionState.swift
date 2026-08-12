/// The mobile-visible lifecycle state of a Claude harness session.
public enum SupermuxClaudeSessionState: String, CaseIterable, Codable, Sendable, Equatable {
    /// The launcher process is starting or completing its initial handshake.
    case starting
    /// The process is ready for another prompt.
    case idle
    /// A prompt is running or an interrupt is settling.
    case working
    /// The session ended and remains available for inspection or resume.
    case ended
    /// The session could not start or exited with an unrecoverable failure.
    case failed
}

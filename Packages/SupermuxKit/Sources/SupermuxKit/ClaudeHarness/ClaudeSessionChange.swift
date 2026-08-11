public import Foundation
public import SupermuxClaudeHarness

/// One retained transcript line with its monotonic sequence number.
public struct ClaudeTranscriptLine: Sendable {
    /// Monotonic per-session line number (1-based); consumers detect gaps and
    /// re-anchor from ``ClaudeSession/transcriptTail(afterSeq:)``.
    public let seq: UInt64
    public let line: ClaudeStreamLine

    public init(seq: UInt64, line: ClaudeStreamLine) {
        self.seq = seq
        self.line = line
    }
}

/// One observable change emitted by a ``ClaudeSession``.
public enum ClaudeSessionChange: Sendable {
    /// The process or turn phase changed.
    case stateChanged(process: ClaudeProcessPhase, turn: ClaudeTurnPhase)
    /// One typed protocol line arrived (already multiplexer-filtered),
    /// carrying its monotonic sequence number.
    case line(ClaudeTranscriptLine)
    /// A non-fatal protocol observation.
    case diagnostic(ClaudeHarnessDiagnostic)
    /// The queue contents or states changed.
    case queueChanged([ClaudeQueuedInput])
    /// The process ended; carries the redacted stderr tail when unclean.
    case processEnded(exit: ClaudeProcessExit, stderrTail: String?)
}

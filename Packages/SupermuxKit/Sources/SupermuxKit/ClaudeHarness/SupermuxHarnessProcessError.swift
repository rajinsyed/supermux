import Foundation

/// Errors produced by the single-process Claude harness session.
public enum SupermuxHarnessProcessError: Error, Equatable, Sendable {
    /// A process is already active for this session object.
    case alreadyRunning
    /// No process is active.
    case notRunning
    /// The serialized stdin writer has been closed.
    case inputClosed
    /// Pending stdin data would exceed the one-megabyte queue limit.
    case inputQueueFull
}

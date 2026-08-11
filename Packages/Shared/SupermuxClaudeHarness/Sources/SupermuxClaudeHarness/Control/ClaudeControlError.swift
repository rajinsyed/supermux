import Foundation

/// Failure of one outbound control request.
public enum ClaudeControlError: Error, Sendable, Equatable {
    /// No response arrived before the request's deadline.
    case timedOut(subtype: String)
    /// The process exited while the request was pending.
    case processExited(subtype: String)
    /// Writing the request line to stdin failed.
    case writeFailed(subtype: String, message: String)
    /// The CLI answered with an error response.
    case rejected(subtype: String, message: String?)
}

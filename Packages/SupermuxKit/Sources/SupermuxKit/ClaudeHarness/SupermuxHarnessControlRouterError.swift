/// Errors produced by ``SupermuxHarnessControlRouter``.
public enum SupermuxHarnessControlRouterError: Error, Equatable, Sendable {
    /// The router has closed and no longer accepts requests.
    case closed
    /// A permission request was already cancelled, answered, or never registered.
    case permissionRequestNotFound(String)
    /// The CLI returned an error response for a client-issued request.
    case requestFailed(requestID: String, message: String?)
}

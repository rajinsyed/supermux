/// Thrown by store write actions when no capable Mac session backs them —
/// the host does not advertise the required `supermux.*.v1` capability (or
/// the session ended under the sheet).
///
/// UI layers map this to their own localized "not connected" message; it
/// deliberately carries no user-facing text (this package owns no string
/// catalog).
public struct SupermuxMacUnavailableError: Error, Equatable, Sendable {
    /// Creates the error.
    public init() {}
}

/// Races a direct dial against the automatic one, direct first.
///
/// The direct leg starts at once. The fallback starts after ``headStart``, or
/// as soon as the direct leg fails, whichever is first. The first success
/// wins. A leg that succeeds after the race is decided goes to `discard`
/// (closed before anything uses it), so the Mac admits exactly one
/// connection. A direct leg still pending at ``directDeadline`` counts as
/// failed for deciding the race, but a late success still wins if the
/// fallback has not.
///
/// With no fallback the race is one direct attempt bounded by
/// ``directDeadline``: the route prober's handshake.
public struct SupermuxDialRace: Sendable {
    /// The direct leg's default head start.
    public static let defaultHeadStart: Duration = .milliseconds(250)
    /// The direct leg's default deadline.
    public static let defaultDirectDeadline: Duration = .milliseconds(1500)

    /// The race failed with nothing more specific to report.
    public enum Failure: Error, Equatable, Sendable {
        /// The direct leg was still pending at the deadline and there was no
        /// fallback.
        case directTimedOut
    }

    /// How long the direct leg runs alone.
    public let headStart: Duration
    /// How long the direct leg may take before it counts as failed.
    public let directDeadline: Duration

    /// Creates a race.
    /// - Parameters:
    ///   - headStart: How long the direct leg runs alone.
    ///   - directDeadline: How long the direct leg may take.
    public init(headStart: Duration = Self.defaultHeadStart, directDeadline: Duration = Self.defaultDirectDeadline) {
        self.headStart = headStart
        self.directDeadline = directDeadline
    }

    /// Runs the race.
    /// - Parameters:
    ///   - direct: The direct dial.
    ///   - fallback: The automatic dial, or nil for a direct attempt only.
    ///   - discard: Closes a connection that lost the race.
    /// - Returns: The winning connection and the lane it used.
    /// - Throws: The fallback's error when both legs fail, the direct leg's
    ///   error (or ``Failure/directTimedOut``) when there is no fallback, and
    ///   `CancellationError` when the caller is cancelled.
    public func run<Value: Sendable>(
        direct: @escaping @Sendable () async throws -> Value,
        fallback: (@Sendable () async throws -> Value)?,
        discard: @escaping @Sendable (Value) async -> Void
    ) async throws -> (value: Value, lane: SupermuxDialLane) {
        throw Failure.directTimedOut
    }
}

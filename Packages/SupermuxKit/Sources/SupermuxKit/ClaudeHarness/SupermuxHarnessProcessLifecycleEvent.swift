/// Lifecycle events emitted by ``SupermuxHarnessProcessSession``.
public enum SupermuxHarnessProcessLifecycleEvent: Equatable, Sendable {
    /// The subprocess launched successfully.
    case started(runID: String, processID: Int32)
    /// The subprocess exited and both stdout and stderr finished draining.
    case exited(runID: String, status: Int32)
}

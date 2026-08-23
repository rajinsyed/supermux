/// Failures raised when a requested subagent transcript path is unsafe.
public enum SupermuxHarnessSubagentTranscriptReaderError: Error, Equatable, Sendable {
    /// A session, task, workflow-run, or agent identifier is not a safe path component.
    case invalidIdentifier
    /// A consumer supplied a negative or otherwise invalid logical revision.
    case invalidRevision
    /// An existing transcript or metadata path escapes its configured projects root.
    case unsafeTranscriptPath
}

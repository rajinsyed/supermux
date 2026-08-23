/// Security and validation failures raised while reading Claude task output.
public enum SupermuxHarnessTaskOutputReaderError: Error, Equatable, Sendable {
    /// The task identifier was not observed in protocol frames.
    case unknownTaskID
    /// The task identifier is not a safe path component.
    case invalidTaskID
    /// The supplied protocol-derived path traverses or escapes the configured Claude temporary root.
    case unsafeOutputPath
    /// The validated path exists but is not a regular file.
    case outputIsNotRegularFile
}

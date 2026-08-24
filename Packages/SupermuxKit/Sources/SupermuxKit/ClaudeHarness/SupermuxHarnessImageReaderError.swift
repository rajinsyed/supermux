/// A project-local image could not be read through the harness security boundary.
public enum SupermuxHarnessImageReaderError: Error, Equatable, Sendable {
    /// The path, file type, payload, or image format is unavailable or unsupported.
    case unavailable
}
